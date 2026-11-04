require 'swagger_helper'

describe 'Households (admin) API', type: :request do
  let(:admin) { create(:member, :admin) }
  let(:plan) { 'household-membership-one-month-recurring' }
  let(:address) { { address_street: '12 Main St', address_postal_code: '03101' } }
  let(:primary) { create(:member, address) }
  let(:group) { Group.find_by(groupName: primary.id.to_s) }

  before do
    allow(Service::AuditLogger).to receive(:log)
    sign_in admin
  end

  def household_plan_for(member, settled: true)
    create(:invoice, member: member, resource_id: member.id.to_s, resource_class: 'member', plan_id: plan, settled_at: settled ? Time.now : nil)
  end

  def existing_household
    household_plan_for(primary)
    primary.update_attributes!(groupName: primary.id.to_s)
    Group.create!(groupName: primary.id.to_s, groupRep: primary.fullname, expiry: primary.expirationTime)
  end

  path '/admin/groups' do
    post 'Creates a household for a member on a household plan; works before the payment is accepted, and records that' do
      tags 'Households'
      operationId 'adminCreateGroup'
      consumes 'application/json'
      produces 'application/json'
      security [sessionAuth: []]
      parameter name: :body, in: :body, schema: { type: :object, required: %w[primaryMemberId], properties: { primaryMemberId: { type: :string } } }
      let(:body) { { primaryMemberId: primary.id.to_s } }

      response '201', 'Household created, with size, seats and payment state' do
        before { household_plan_for(primary) }
        schema '$ref' => '#/components/schemas/Group'
        run_test! { |response| expect(JSON.parse(response.body)).to include('size' => 2, 'seatsUsed' => 1, 'paymentAccepted' => true) }
      end

      response '422', 'The member is not on a household plan' do
        schema '$ref' => '#/components/schemas/error'
        run_test!
      end
    end
  end

  path '/admin/groups/{id}/add_member' do
    post 'Links a secondary adult: the household must have a seat, and the address must match unless an admin gives a reason' do
      tags 'Households'
      operationId 'adminAddGroupMember'
      consumes 'application/json'
      produces 'application/json'
      security [sessionAuth: []]
      parameter name: :id, in: :path, type: :string
      parameter name: :body, in: :body, schema: {
        type: :object, required: %w[secondaryMemberId],
        properties: {
          secondaryMemberId: { type: :string },
          addressOverrideReason: { type: :string, description: 'Lets a mismatched address through. Recorded in the audit log with both addresses. Admin only.' }
        }
      }
      let(:id) { existing_household.id.to_s }
      let(:secondary) { create(:member, address) }
      let(:body) { { secondaryMemberId: secondary.id.to_s } }

      response '200', 'Linked; the household with seats and payment state' do
        schema '$ref' => '#/components/schemas/Group'
        run_test! { |response| expect(JSON.parse(response.body)).to include('seatsUsed' => 2, 'paymentAccepted' => true) }
      end

      response '422', 'Address mismatch (message starts "Address mismatch:") or the household is full' do
        schema '$ref' => '#/components/schemas/error'
        let(:secondary) { create(:member, address_street: '99 Other Rd', address_postal_code: '03101') }
        run_test! { |response| expect(response.body).to match(/Address mismatch/) }
      end
    end
  end
end
