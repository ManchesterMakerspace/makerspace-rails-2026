require 'swagger_helper'

RSpec.describe 'Tool group API', type: :request do
  let(:member) { create(:member, :current, :admin) }
  let(:shop) { create(:shop) }
  let(:tool) { create(:tool, shop: shop) }
  let(:group) { ToolGroup.create!(shop: shop, name: 'Starter kit', included_tool_ids: [tool.id.to_s]) }
  let(:id) { group.id.to_s }
  before do
    sign_in member
    allow(REDIS).to receive(:set).and_return(true)
    allow(REDIS).to receive(:eval).and_return(1)
    allow(ToolGroupCheckout).to receive(:notify)
  end

  path '/tool_groups' do
    get 'List authenticated groups separately from physical tools' do
      tags 'Tool groups'
      security [sessionAuth: []]
      produces 'application/json'
      parameter name: :shop_id, in: :query, required: false, schema: { type: :string }
      response('200', 'Active groups with permission-scoped physical tool details') do
        before { group }
        schema type: :array, items: { type: :object, required: %w[id name revision includedTools], properties: {
          id: { type: :string }, name: { type: :string }, revision: { type: :integer },
          includedTools: { type: :array, items: { '$ref' => '#/components/schemas/Tool' } }
        } }
        run_test!
      end
    end
    post 'Create a group (Admin, Board or shop RM)' do
      tags 'Tool groups'
      security [sessionAuth: []]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, schema: { type: :object, required: %w[name shop_id included_tool_ids], properties: {
        name: { type: :string }, shop_id: { type: :string }, description: { type: :string },
        included_tool_ids: { type: :array, minItems: 1, items: { type: :string } },
        prerequisite_ids: { type: :array, items: { type: :string } }, reservable: { type: :boolean, default: false },
        requestable: { type: :boolean, default: false }, announce: { type: :boolean, default: false }, announce_channel: { type: :string }
      } }
      let(:body) { { shop_id: shop.id.to_s, name: 'New kit', included_tool_ids: [tool.id.to_s] } }
      response('200', 'Created') { run_test! }
      response('403', 'Shop management required') do
        let(:member) { create(:member, :current) }
        run_test!
      end
    end
  end

  path '/tool_groups/{id}' do
    parameter name: :id, in: :path, schema: { type: :string }
    get 'Read an authenticated group' do
      tags 'Tool groups'; security [sessionAuth: []]; produces 'application/json'
      response('200', 'Group') { run_test! }
    end
    put 'Edit a group with optimistic revision checking (Admin, Board or shop RM)' do
      tags 'Tool groups'; security [sessionAuth: []]; consumes 'application/json'; produces 'application/json'
      parameter name: :body, in: :body, schema: { type: :object, required: ['revision'], properties: {
        revision: { type: :integer }, name: { type: :string }, description: { type: :string },
        included_tool_ids: { type: :array, minItems: 1, items: { type: :string } },
        prerequisite_ids: { type: :array, items: { type: :string } }, reservable: { type: :boolean },
        requestable: { type: :boolean }, announce: { type: :boolean }, announce_channel: { type: :string }
      } }
      let(:body) { { revision: group.revision, name: 'Renamed kit' } }
      response('200', 'Updated') { run_test! }
      response('409', 'Stale revision; refresh review') do
        let(:body) { { revision: 0, name: 'Stale' } }
        run_test!
      end
    end
    delete 'Archive a group and cancel open requests, preserving historical records' do
      tags 'Tool groups'; security [sessionAuth: []]; consumes 'application/json'
      parameter name: :body, in: :body, schema: { type: :object, required: ['revision'], properties: { revision: { type: :integer } } }
      let(:body) { { revision: group.revision } }
      response('204', 'Archived') { run_test! }
    end
  end

  path '/tool_groups/{id}/review' do
    parameter name: :id, in: :path, schema: { type: :string }
    get 'Review current included, held, prerequisite and proposed checkout IDs' do
      tags 'Tool groups'; security [sessionAuth: []]; produces 'application/json'
      parameter name: :member_id, in: :query, required: false, schema: { type: :string }, description: 'Another member requires group approval authority'
      response('200', 'Current revision and physical checkout review') { run_test! }
    end
  end
  path '/tool_groups/{id}/approve' do
    parameter name: :id, in: :path, schema: { type: :string }
    post 'Atomically approve individual checkouts for a reviewed group' do
      tags 'Tool groups'; security [sessionAuth: []]; consumes 'application/json'; produces 'application/json'
      parameter name: :body, in: :body, schema: { type: :object, required: %w[member_id revision], properties: {
        member_id: { type: :string }, revision: { type: :integer }, request_id: { type: :string }
      } }
      let(:body) { { member_id: member.id.to_s, revision: group.revision } }
      response('200', 'Created and skipped checkouts with shared approvalBatchId') do
        schema type: :object, required: %w[checkouts skipped approvalBatchId], properties: {
          checkouts: { type: :array, items: { '$ref' => '#/components/schemas/ToolCheckout' } },
          skipped: { type: :array, items: { '$ref' => '#/components/schemas/ToolCheckout' } },
          approvalBatchId: { type: :string, nullable: true }
        }
        run_test!
      end
      response('409', 'Stale group revision') do
        let(:body) { { member_id: member.id.to_s, revision: 0 } }
        run_test!
      end
    end
  end

  path '/tool_groups/{id}/volunteer' do
    parameter name: :id, in: :path, schema: { type: :string }
    post 'Volunteer for group authority with all current included checkouts' do
      tags 'Tool groups'; security [sessionAuth: []]; consumes 'application/json'; produces 'application/json'
      parameter name: :body, in: :body, schema: { type: :object, properties: { note: { type: :string, maxLength: 128 } } }
      let(:body) { { note: 'Available to train' } }
      before { ToolCheckout.create!(member: member, tool: tool, defer_users_channel_invitation: true) }
      response('200', 'Open volunteer request') { run_test! }
    end
  end
  path '/tool_groups/{id}/volunteers' do
    parameter name: :id, in: :path, schema: { type: :string }
    get 'List open volunteers using existing shop-reviewer permissions' do
      tags 'Tool groups'; security [sessionAuth: []]; produces 'application/json'
      before { member.update!(resource_manager_shop_ids: [shop.id.to_s]) }
      response('200', 'Open volunteer requests') { run_test! }
    end
  end
  path '/tool_groups/{id}/decide_volunteer' do
    parameter name: :id, in: :path, schema: { type: :string }
    post 'Decide a volunteer request, revalidating membership and held checkouts' do
      tags 'Tool groups'; security [sessionAuth: []]; consumes 'application/json'; produces 'application/json'
      parameter name: :body, in: :body, schema: { type: :object, required: %w[request_id decision], properties: {
        request_id: { type: :string }, decision: { type: :string, enum: %w[approved declined] }, note: { type: :string, maxLength: 128 }
      } }
      let(:volunteer) { create(:member, :current) }
      let(:request) do
        ToolCheckout.create!(member: volunteer, tool: tool, defer_users_channel_invitation: true)
        CheckoutApproverRequest.create!(member: volunteer, tool_group: group)
      end
      let(:body) { { request_id: request.id.to_s, decision: 'approved' } }
      before { member.update!(resource_manager_shop_ids: [shop.id.to_s]) }
      response('200', 'Decision recorded') { run_test! }
    end
  end
end
