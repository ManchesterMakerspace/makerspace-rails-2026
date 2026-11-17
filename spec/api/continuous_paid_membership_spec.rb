require 'swagger_helper'

describe 'Continuous paid membership API', type: :request do
  let(:member) { create(:member) }
  let(:id) { member.id.to_s }

  path '/members/{id}/continuous_paid_membership' do
    parameter name: :id, in: :path, type: :string, required: true
    get 'Read stored continuous paid membership months (self, Admin, or Board)' do
      tags 'PaidMembership'
      operationId 'getContinuousPaidMembership'
      produces 'application/json'
      response '200', 'stored balance with effective expiration reset' do
        schema '$ref' => '#/components/schemas/ContinuousPaidMembership'
        before { sign_in member }
        run_test!
      end
      response '401', 'authentication or completed TOTP required' do
        run_test!
      end
      response '403', 'another ordinary member or Resource Manager' do
        before { sign_in create(:member, :resource_manager) }
        run_test!
      end
      response '404', 'member not found' do
        let(:id) { BSON::ObjectId.new.to_s }
        before { sign_in create(:member, :admin) }
        run_test!
      end
    end
  end

  path '/admin/members/{id}/continuous_paid_membership' do
    parameter name: :id, in: :path, type: :string, required: true
    put 'Increase a paid balance with a required audited correction reason (Admin only)' do
      tags 'PaidMembership'
      operationId 'increaseContinuousPaidMembership'
      consumes 'application/json'
      produces 'application/json'
      parameter name: :increasePaidMembership, in: :body, required: true,
        schema: { '$ref' => '#/components/schemas/IncreaseContinuousPaidMembership' }
      let(:increasePaidMembership) { { continuousPaidMembershipMonths: 3, expectedRevision: 0, reason: 'Verified missing history' } }
      response '200', 'increase and audit committed atomically', requires_transactions: true do
        schema '$ref' => '#/components/schemas/ContinuousPaidMembership'
        before { sign_in create(:member, :admin) }
        run_test! { expect(member.reload.continuous_paid_membership_months).to eq(3) }
      end
      response '401', 'authentication, CSRF, or completed TOTP required' do
        run_test!
      end
      response '403', 'Admin role required; Board cannot correct balances' do
        before { sign_in create(:member, :board_member) }
        run_test!
      end
      response '404', 'member not found', requires_transactions: true do
        let(:id) { BSON::ObjectId.new.to_s }
        before { sign_in create(:member, :admin) }
        run_test!
      end
      response '409', 'expected revision is stale', requires_transactions: true do
        let(:increasePaidMembership) { super().merge(expectedRevision: 42) }
        before { sign_in create(:member, :admin) }
        run_test!
      end
      response '422', 'invalid increase, reason, eligibility, or unavailable transaction service' do
        let(:increasePaidMembership) { super().merge(continuousPaidMembershipMonths: 1.5) }
        before { sign_in create(:member, :admin) }
        run_test!
      end
    end
  end
end
