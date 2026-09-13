require 'swagger_helper'

RSpec.describe 'Checkout approver contracts', type: :request do
  let(:member) { create(:member, :admin, :current) }
  let(:shop) { create(:shop) }
  let(:tool) { create(:tool, shop: shop, out_of_service: true) }
  let(:approver) { CheckoutApprover.create!(member_id: member.id, shop_ids: [shop.id.to_s], tool_ids: [tool.id.to_s]) }
  before { sign_in member; allow(REDIS).to receive(:set) }
  path '/admin/checkout_approvers' do
    get 'List checkout approvers including per-tool availability' do
      tags 'Tool checkouts'
      security [sessionAuth: []]
      produces 'application/json'
      response('200', 'Approvers') do
        schema type: :array, items: { '$ref' => '#/components/schemas/CheckoutApprover' }
        before { approver }
        run_test! { |r| expect(JSON.parse(r.body).first['tools'].first['outOfService']).to eq(true) }
      end
    end
    post 'Create or extend an approver scope (admin/board)' do
      tags 'Tool checkouts'
      security [sessionAuth: []]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, schema: { '$ref' => '#/components/schemas/CheckoutApproverWrite' }
      let(:body) { { member_id: member.id.to_s, tool_ids: [tool.id.to_s], shop_ids: [] } }
      response('200', 'Saved approver') { schema '$ref' => '#/components/schemas/CheckoutApprover'; run_test! }
      response('403', 'Admin or board membership required') do
        let(:member) { create(:member, :current) }
        run_test!
      end
    end
  end
  path '/admin/checkout_approvers/{id}' do
    parameter name: :id, in: :path, type: :string
    let(:id) { approver.id.to_s }
    %i[put patch].each do |verb|
      public_send(verb, 'Replace supplied approver fields (admin/board)') do
        tags 'Tool checkouts'
        security [sessionAuth: []]
        consumes 'application/json'
        produces 'application/json'
        parameter name: :body, in: :body, schema: { '$ref' => '#/components/schemas/CheckoutApproverWrite' }
        let(:body) { { tool_ids: [tool.id.to_s], shop_ids: [] } }
        response('200', 'Updated approver') { schema '$ref' => '#/components/schemas/CheckoutApprover'; run_test! }
      end
    end
    delete 'Delete an approver (admin/board)' do
      tags 'Tool checkouts'
      security [sessionAuth: []]
      response('204', 'Deleted') { run_test! }
    end
  end
end
