require 'rails_helper'

RSpec.describe MemberMailer, 'household emails' do
  let(:plan) { 'household-membership-one-month-recurring' }
  let(:primary) { create(:member, firstname: 'Pat', lastname: 'Primary', address_street: '12 Main St', address_postal_code: '03101', expirationTime: nil) }

  before do
    ActiveJob::Base.queue_adapter = :test
    allow(Service::AuditLogger).to receive(:log)
    allow(Service::SlackConnector).to receive(:enque_message)
    create(:invoice, member: primary, resource_id: primary.id.to_s, resource_class: 'member', plan_id: plan, settled_at: Time.now)
  end

  describe '#household_invitation' do
    let(:invitation) { HouseholdInvitations.invite!(primary: primary, email: 'second@example.com') }
    let(:mail) { described_class.household_invitation(invitation.id.to_s, 'THE-TOKEN') }

    it 'goes to the address the primary typed, with the link and the rules' do
      expect(mail.to).to eq(['second@example.com'])
      expect(mail.subject).to match(/Pat invited you/)
      body = mail.body.encoded
      expect(body).to include('/household/join?token=THE-TOKEN')
      expect(body).to include('Pat Primary')
      expect(body).to match(/free/i)
      expect(body).to match(/photo ID/)
      expect(body).to match(/in person/)
      expect(body).to include(invitation.expires_at.in_time_zone.strftime('%B %-d, %Y'))
    end

    it 'does not put the household address in the email' do
      expect(mail.body.encoded).not_to match(/Main St|03101/)
    end
  end

  describe '#household_joined' do
    it 'tells each adult about the other and what to do at the desk' do
      second = create(:member, firstname: 'Sam', lastname: 'Second', address_street: '12 Main St', address_postal_code: '03101')

      to_second = described_class.household_joined(second.id.to_s, primary.id.to_s)
      to_primary = described_class.household_joined(primary.id.to_s, second.id.to_s)

      expect(to_second.to).to eq([second.email])
      expect(to_second.body.encoded).to include('Pat Primary').and match(/photo ID/)
      expect(to_primary.to).to eq([primary.email])
      expect(to_primary.body.encoded).to include('Sam Second')
    end
  end
end
