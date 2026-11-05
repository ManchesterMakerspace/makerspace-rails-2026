require 'rails_helper'

RSpec.describe Admin::GroupsController, 'household rules', type: :controller do
  set_devise_mapping

  let(:admin) { create(:member, :admin, firstname: 'Ada', lastname: 'Admin') }
  let(:plan) { 'household-membership-one-month-recurring' }
  let(:address) { { address_street: '12 Main St', address_postal_code: '03101' } }
  let(:primary) do
    member = create(:member, address)
    create(:invoice, member: member, resource_id: member.id.to_s, resource_class: 'member', plan_id: plan, settled_at: Time.now)
    member.update_attributes!(groupName: member.id.to_s)
    Group.create!(groupName: member.id.to_s, groupRep: member.fullname, expiry: member.expirationTime)
    member
  end
  let(:group) { Group.find_by(groupName: primary.id.to_s) }

  before do
    sign_in admin
    allow(Service::AuditLogger).to receive(:log).and_call_original
  end

  def add(secondary, extra = {})
    post :add_member, params: { id: group.id.to_s, secondary_member_id: secondary.id.to_s }.merge(extra), format: :json
  end

  describe 'POST #add_member' do
    it 'links a member whose address matches loosely' do
      secondary = create(:member, address_street: '12 Main Street Unit 2', address_postal_code: '03101')

      add(secondary)

      expect(response).to have_http_status(200)
      expect(secondary.reload.groupName).to eq(primary.id.to_s)
    end

    it 'refuses a different address with a message the screen can recognize' do
      add(create(:member, address_street: '99 Other Rd', address_postal_code: '03101'))

      expect(response).to have_http_status(422)
      expect(response.body).to match(/Address mismatch/)
    end

    it 'allows a different address with a reason, and records the reason and both addresses' do
      secondary = create(:member, address_street: '99 Other Rd', address_postal_code: '03101')

      add(secondary, address_override_reason: 'Family moving in')

      expect(response).to have_http_status(200)
      expect(secondary.reload.groupName).to eq(primary.id.to_s)
      expect(Service::AuditLogger).to have_received(:log).with(hash_including(
        event_type: 'household_member_added',
        message_details: a_string_including('Ada Admin overrode the address check', '99 Other Rd, 03101', '12 Main St, 03101', 'Family moving in'),
        after_snapshot: hash_including(address_override: hash_including(reason: 'Family moving in'))
      ))
    end

    it 'refuses a member when the household is full' do
      add(create(:member, address))
      add(create(:member, address))

      expect(response).to have_http_status(422)
      expect(response.body).to match(/household is full/)
    end

    it 'still works before the household payment is accepted, and records that the admin continued' do
      Invoice.where(resource_id: primary.id.to_s).update_all(settled_at: nil)
      secondary = create(:member, address)

      add(secondary)

      expect(response).to have_http_status(200)
      expect(Service::AuditLogger).to have_received(:log).with(hash_including(
        event_type: 'household_member_added',
        message_details: a_string_including('payment had not been accepted yet'),
        after_snapshot: hash_including(payment_accepted: false)
      ))
    end

    it 'does not mention payment when it was accepted' do
      add(create(:member, address))

      expect(Service::AuditLogger).to have_received(:log).with(hash_including(event_type: 'household_member_added'))
      expect(Service::AuditLogger).not_to have_received(:log).with(hash_including(after_snapshot: hash_including(payment_accepted: false)))
    end

    it 'returns the size, seats and payment state with the household' do
      add(create(:member, address))

      body = JSON.parse(response.body)
      expect(body).to include('size' => 2, 'seatsUsed' => 2, 'paymentAccepted' => true)
      expect(body['secondaryMembers'].first).to include('fobIssued' => false)
    end
  end

  describe 'POST #create' do
    it 'works before the household payment is accepted and records that the admin continued' do
      member = create(:member, address)
      create(:invoice, member: member, resource_id: member.id.to_s, resource_class: 'member', plan_id: plan, settled_at: nil)

      post :create, params: { primary_member_id: member.id.to_s }, format: :json

      expect(response).to have_http_status(201)
      expect(Service::AuditLogger).to have_received(:log).with(hash_including(
        event_type: 'household_created',
        message_details: a_string_including('payment had not been accepted yet'),
        after_snapshot: hash_including(payment_accepted: false)
      ))
    end
  end
end
