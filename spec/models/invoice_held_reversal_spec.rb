require 'rails_helper'

# A payment taken from a member with no fob is held (the invoice has a transaction but is not applied) until their first
# fob. A declined settlement must not take months off a membership that never had them, and must not be applied later.
RSpec.describe Invoice, 'reversing a payment' do
  let(:plan) { 'household-membership-one-month-recurring' }

  before do
    ActiveJob::Base.queue_adapter = :test
    allow(Service::AuditLogger).to receive(:log)
    allow(Service::SlackConnector).to receive(:enque_message)
    allow(Service::SlackConnector).to receive(:send_slack_message)
  end

  def held_invoice(member, transaction_id: 'tx-held')
    create(:invoice, member: member, resource_id: member.id.to_s, resource_class: 'member', plan_id: plan, quantity: 1,
                     transaction_id: transaction_id, settled_at: nil)
  end

  describe 'a held payment (member has no fob yet)' do
    let(:member) { create(:member, expirationTime: nil) }

    it 'leaves the member without an expiry and records the decline' do
      invoice = held_invoice(member)

      invoice.reverse_settlement

      expect(member.reload.expirationTime).to be_nil
      expect(invoice.reload.last_failed_transaction_id).to eq('tx-held')
      expect(invoice.settled_at).to be_nil
    end

    it 'is not applied when the first fob is issued after the decline' do
      invoice = held_invoice(member)
      invoice.reverse_settlement

      create(:card, member: member)

      expect(member.reload.expirationTime).to be_nil
      expect(invoice.reload.settled_at).to be_nil
    end

    it 'still applies a held payment that was not declined when the first fob is issued' do
      invoice = held_invoice(member)

      create(:card, member: member)

      expect(invoice.reload.settled_at).to be_present
      expect(member.reload.expirationTime).to be > Time.now.to_i * 1000
    end
  end

  describe 'an applied payment' do
    let(:plan_expiry) { (Time.now + 60.days).to_i * 1000 }
    let(:primary) { create(:member, address_street: '12 Main St', address_postal_code: '03101', expirationTime: plan_expiry) }

    it 'takes the months back off the expiry' do
      create(:card, member: primary)
      invoice = create(:invoice, member: primary, resource_id: primary.id.to_s, resource_class: 'member', plan_id: plan, quantity: 1,
                                 transaction_id: 'tx-applied', settled_at: Time.now)
      before = primary.reload.expirationTime

      invoice.reverse_settlement

      expect(primary.reload.expirationTime).to be < before
      expect(invoice.reload.settled_at).to be_nil
    end

    it 'rolls the household back with the primary: secondaries and cards follow the new expiry' do
      create(:card, member: primary)
      invoice = create(:invoice, member: primary, resource_id: primary.id.to_s, resource_class: 'member', plan_id: plan, quantity: 1,
                                 transaction_id: 'tx-applied', settled_at: Time.now)
      primary.update_attributes!(groupName: primary.id.to_s)
      group = Group.create!(groupName: primary.id.to_s, groupRep: primary.fullname, expiry: plan_expiry)
      secondary = create(:member, address_street: '12 Main St', address_postal_code: '03101')
      group.add_subordinate(secondary)
      create(:card, member: secondary)
      expect(secondary.reload.expirationTime).to eq(plan_expiry)

      invoice.reverse_settlement

      rolled_back = primary.reload.expirationTime
      expect(rolled_back).to be < plan_expiry
      expect(group.reload.expiry).to eq(rolled_back)
      expect(secondary.reload.expirationTime).to eq(rolled_back)
      expect(secondary.access_cards.map(&:expiry)).to all(eq(rolled_back))
      expect(group.secondary_members.map(&:id)).to eq([secondary.id])
    end
  end
end
