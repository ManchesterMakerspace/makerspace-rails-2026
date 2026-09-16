require 'swagger_helper'

RSpec.describe 'Tool Checkouts API', type: :request do
  let(:shop) { Shop.create!(name: 'Woodshop') }
  let(:tool) { Tool.create!(name: 'Disabled Bandsaw', shop: shop, disabled: true) }
  let(:member) { create(:member, :current) }
  let(:resource_manager) do
    create(:member, :resource_manager, :current, resource_manager_shop_ids: [shop.id.to_s])
  end

  before do
    allow(REDIS).to receive(:set)
    allow(Service::SlackConnector).to receive(:send_slack_message)
    sign_in resource_manager
  end

  describe 'POST /api/admin/tool_checkouts' do
    it 'allows resource managers to check out members on disabled tools' do
      post '/api/admin/tool_checkouts', params: {
        member_id: member.id.to_s,
        tool_id: tool.id.to_s
      }

      expect(response).to have_http_status(:ok)
      expect(ToolCheckout.where(member_id: member.id, tool_id: tool.id, revoked_at: nil)).to exist
      audit_log = AuditLog.where(
        event_type: 'tool_checkout_created',
        subject_id: member.id
      ).last
      expect(audit_log.slack_message).to include(
        'shop: Woodshop',
        'tool: Disabled Bandsaw'
      )
    end

    it 'allows pending members to receive a checkout for an enabled onboarding tool' do
      pending_member = create(:member, :current, status: 'pending')
      orientation = Tool.create!(
        name: 'Orientation',
        shop: shop,
        allow_pending: true
      )

      post '/api/admin/tool_checkouts', params: {
        member_id: pending_member.id.to_s,
        tool_id: orientation.id.to_s
      }

      expect(response).to have_http_status(:ok)
      expect(ToolCheckout.where(member_id: pending_member.id, tool_id: orientation.id, revoked_at: nil)).to exist
    end

    it 'allows staff to issue an ordinary tool checkout to a pending member' do
      pending_member = create(:member, :current, status: 'pending')
      ordinary_tool = Tool.create!(name: 'Table Saw', shop: shop)

      post '/api/admin/tool_checkouts', params: {
        member_id: pending_member.id.to_s,
        tool_id: ordinary_tool.id.to_s
      }

      expect(response).to have_http_status(:ok)
      expect(ToolCheckout.where(member_id: pending_member.id, tool_id: ordinary_tool.id, revoked_at: nil)).to exist
    end
  end

  describe 'DELETE /api/admin/tool_checkouts/:id' do
    it 'allows resource managers to revoke checkouts for disabled tools' do
      original_approver = create(
        :member,
        :resource_manager,
        :current,
        resource_manager_shop_ids: [shop.id.to_s]
      )
      SlackUser.create!(member: original_approver, slack_id: 'UORIGINAL', slack_email: original_approver.email)
      checkout = ToolCheckout.create!(member: member, tool: tool, approved_by: original_approver)

      delete "/api/admin/tool_checkouts/#{checkout.id}", params: {
        revocation_reason: 'Safety retraining required'
      }

      expect(response).to have_http_status(:ok)
      expect(checkout.reload.revoked_at).to be_present
      expect(checkout.revocation_reason).to eq('Safety retraining required')
      audit_log = AuditLog.where(event_type: 'tool_checkout_revoked', resource_id: checkout.id).last
      expect(audit_log.slack_message).to include('shop: Woodshop', 'tool: Disabled Bandsaw')
      expect(Service::SlackConnector).to have_received(:send_slack_message).with(
        a_string_including('Your approval', 'Disabled Bandsaw', 'an RM'),
        'UORIGINAL'
      )
    end

    it 'completes revocation bookkeeping when the approver DM fails' do
      checkout = ToolCheckout.create!(
        member: member,
        tool: tool,
        approved_by: create(:member, :resource_manager, :current, resource_manager_shop_ids: [shop.id.to_s])
      )
      allow_any_instance_of(ToolCheckout).to receive(:send_approver_revocation_slack_notification)
        .and_raise(StandardError, 'account_inactive')
      expect_any_instance_of(ToolCheckout).to receive(:remove_member_from_users_channel)
      allow(Service::ErrorReporter).to receive(:notify)

      delete "/api/admin/tool_checkouts/#{checkout.id}", params: {
        revocation_reason: 'Safety retraining required'
      }

      expect(response).to have_http_status(:ok)
      expect(checkout.reload.revoked_at).to be_present
      expect(AuditLog.where(event_type: 'tool_checkout_revoked', resource_id: checkout.id)).to exist
      expect(Service::ErrorReporter).to have_received(:notify).with(
        instance_of(StandardError),
        context: hash_including(checkout_id: checkout.id.to_s)
      )
    end
  end
end

RSpec.describe 'Admin tool checkouts API', type: :request do
  before { allow(REDIS).to receive(:set) }

  path '/admin/tool_checkouts/{id}' do
    delete 'Revokes a tool checkout' do
      tags 'AdminToolCheckouts'
      operationId 'revokeAdminToolCheckout'
      consumes 'application/json'
      produces 'application/json'
      parameter name: :id, in: :path, type: :string, required: true,
        description: 'Tool checkout ID'
      parameter name: :revocation_details, in: :body, schema: {
        type: :object,
        properties: {
          revocation_reason: { type: :string }
        },
        required: ['revocation_reason']
      }

      response '200', 'checkout revoked even when the best-effort approver notification fails' do
        let(:shop) { create(:shop) }
        let(:tool) { create(:tool, shop: shop) }
        let(:member) { create(:member, :current) }
        let(:resource_manager) do
          create(:member, :resource_manager, :current, resource_manager_shop_ids: [shop.id.to_s])
        end
        let(:checkout) { create(:tool_checkout, member: member, tool: tool, approved_by: resource_manager) }
        let(:id) { checkout.id.to_s }
        let(:revocation_details) { { revocation_reason: 'Safety retraining required' } }

        before do
          sign_in resource_manager
          allow_any_instance_of(ToolCheckout).to receive(:send_revocation_slack_notification)
          allow_any_instance_of(ToolCheckout).to receive(:send_approver_revocation_slack_notification)
            .and_raise(StandardError, 'account_inactive')
          allow_any_instance_of(ToolCheckout).to receive(:remove_member_from_users_channel)
          allow(Service::ErrorReporter).to receive(:notify)
          allow(Service::AuditLogger).to receive(:log)
        end

        schema type: :object,
          properties: {
            id: { type: :string },
            memberId: { type: :string },
            toolId: { type: :string },
            checkedOutAt: { type: :string, format: 'date-time' },
            revokedAt: { type: :string, format: 'date-time' },
            revocationReason: { type: :string },
            approvedById: { type: :string, nullable: true },
            active: { type: :boolean }
          },
          required: %w[id memberId toolId checkedOutAt revokedAt revocationReason active]

        run_test! do |response|
          expect(response).to have_http_status(:ok)
          expect(checkout.reload.revoked_at).to be_present
          expect(Service::ErrorReporter).to have_received(:notify).with(
            instance_of(StandardError),
            context: hash_including(checkout_id: checkout.id.to_s)
          )
        end
      end

      response '422', 'revocation reason is required' do
        let(:shop) { create(:shop) }
        let(:resource_manager) do
          create(:member, :resource_manager, :current, resource_manager_shop_ids: [shop.id.to_s])
        end
        let(:id) { create(:tool_checkout, tool: create(:tool, shop: shop)).id.to_s }
        let(:revocation_details) { {} }
        before { sign_in resource_manager }

        schema '$ref' => '#/components/schemas/error'
        run_test!
      end
    end
  end
end
