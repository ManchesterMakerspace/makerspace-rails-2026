require 'rails_helper'

RSpec.describe 'Tool checkout requests', type: :request do
  let(:shop) { Shop.create!(name: 'Woodshop', slack_channel: 'woodshop') }
  let(:tool) { Tool.create!(name: 'Table Saw', shop: shop) }
  let(:prereq) { Tool.create!(name: 'Safety Class', shop: shop) }
  let(:member) { create(:member, :current) }

  before do
    allow(Service::SlackConnector).to receive(:send_slack_message).and_return({ 'ts' => '123.456' })
    allow(Service::SlackConnector).to receive(:update_slack_message)
  end

  describe 'GET /api/tool_checkout_requests/available_tools' do
    xit 'lists tools without any checkout record and includes unmet prerequisites' do
      unavailable = Tool.create!(name: 'Band Saw', shop: shop)
      ToolCheckout.create!(member: member, tool: unavailable)
      tool.update_attributes!(prerequisite_ids: [prereq.id])

      sign_in member
      get '/api/tool_checkout_requests/available_tools'

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body.map { |t| t['id'] }).to include(tool.id.to_s)
      expect(body.map { |t| t['id'] }).not_to include(unavailable.id.to_s)
      listed = body.detect { |t| t['id'] == tool.id.to_s }
      expect(listed['unmet_prerequisite_ids']).to eq([prereq.id.to_s])
      expect(listed['unmet_prerequisite_names']).to eq(['Safety Class'])
      expect(listed['requestable']).to eq(false)
    end
  end

  describe 'POST /api/tool_checkout_requests' do
    it 'creates an open request with a note when the member is active and prerequisites are met' do
      tool.update_attributes!(prerequisite_ids: [prereq.id])
      ToolCheckout.create!(member: member, tool: prereq)

      sign_in member
      expect do
        post '/api/tool_checkout_requests', params: { tool_id: tool.id.to_s, note: 'Please approve me' }
      end.to change(ToolCheckoutRequest, :count).by(1)

      expect(response).to have_http_status(:created)
      request_record = ToolCheckoutRequest.last
      expect(request_record.status).to eq('open')
      expect(request_record.member_id).to eq(member.id)
      expect(request_record.note).to eq('Please approve me')
    end

    it 'rejects requests when prerequisites are unmet' do
      tool.update_attributes!(prerequisite_ids: [prereq.id])

      sign_in member
      post '/api/tool_checkout_requests', params: { tool_id: tool.id.to_s }

      expect(response).to have_http_status(422)
      expect(ToolCheckoutRequest.count).to eq(0)
    end

    it 'rejects requests from expired members' do
      expired = create(:member, :expired)

      sign_in expired
      post '/api/tool_checkout_requests', params: { tool_id: tool.id.to_s }

      expect(response).to have_http_status(403)
      expect(ToolCheckoutRequest.count).to eq(0)
    end

    it 'validates note length' do
      sign_in member
      post '/api/tool_checkout_requests', params: { tool_id: tool.id.to_s, note: 'x' * 129 }

      expect(response).to have_http_status(422)
      expect(ToolCheckoutRequest.count).to eq(0)
    end
  end

  describe 'member management of own open requests' do
    it 'allows members to view, update note, and delete their own open valid requests' do
      request_record = ToolCheckoutRequest.create!(member: member, tool: tool, note: 'old')

      sign_in member
      get '/api/tool_checkout_requests'
      expect(JSON.parse(response.body).map { |r| r['id'] }).to eq([request_record.id.to_s])

      put "/api/tool_checkout_requests/#{request_record.id}", params: { note: 'new' }
      expect(response).to have_http_status(:ok)
      expect(request_record.reload.note).to eq('new')

      delete "/api/tool_checkout_requests/#{request_record.id}"
      expect(response).to have_http_status(204)
      expect(ToolCheckoutRequest.where(id: request_record.id)).to be_empty
    end

    it 'does not allow members to edit closed requests' do
      request_record = ToolCheckoutRequest.create!(member: member, tool: tool, status: 'closed')

      sign_in member
      put "/api/tool_checkout_requests/#{request_record.id}", params: { note: 'new' }

      expect(response).to have_http_status(404)
      expect(request_record.reload.note).to be_nil
    end
  end

  describe 'GET /api/admin/tool_checkout_requests' do
    it 'allows admins to see all requests for valid tools' do
      admin = create(:member, :admin)
      request_record = ToolCheckoutRequest.create!(member: member, tool: tool)

      sign_in admin
      get '/api/admin/tool_checkout_requests'

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body).map { |r| r['id'] }).to include(request_record.id.to_s)
    end

    it 'allows checkout approvers to see open requests for their shops by active unexpired members' do
      other_shop = Shop.create!(name: 'Metal', slack_channel: 'metal')
      other_tool = Tool.create!(name: 'Welder', shop: other_shop)
      approver = create(:member)
      CheckoutApprover.create!(member: approver, shop_ids: [shop.id])
      visible = ToolCheckoutRequest.create!(member: member, tool: tool)
      ToolCheckoutRequest.create!(member: member, tool: other_tool)
      ToolCheckoutRequest.create!(member: create(:member, :expired), tool: tool)

      sign_in approver
      get '/api/admin/tool_checkout_requests'

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body).map { |r| r['id'] }).to eq([visible.id.to_s])
    end
  end

  describe 'checkout creation integration' do
    it 'closes an open request when a checkout is created for the same member and tool' do
      admin = create(:member, :admin)
      request_record = ToolCheckoutRequest.create!(member: member, tool: tool)

      sign_in admin
      post '/api/admin/tool_checkouts', params: { member_id: member.id.to_s, tool_id: tool.id.to_s }

      expect(response).to have_http_status(:ok)
      expect(request_record.reload.status).to eq('closed')
      expect(request_record.checked_out).to eq(ToolCheckout.last.id)
    end
  end
end

RSpec.describe 'Tool checkout approver management', type: :request do
  let(:shop) { Shop.create!(name: 'Woodshop', slack_channel: 'woodshop') }
  let(:other_shop) { Shop.create!(name: 'Metal', slack_channel: 'metal') }
  let(:member) { create(:member, :current) }
  let(:approver) { create(:member, :current) }
  let(:tool) { Tool.create!(name: 'Table Saw', shop: shop) }
  let(:prereq) { Tool.create!(name: 'Safety Class', shop: other_shop) }
  let(:other_tool) { Tool.create!(name: 'Welder', shop: other_shop) }

  before do
    allow(Service::SlackConnector).to receive(:send_slack_message).and_return({ 'ts' => '123.456' })
    allow(Service::SlackConnector).to receive(:update_slack_message)
    CheckoutApprover.create!(member: approver, shop_ids: [shop.id])
  end

  it 'adds Tool Checkouts permission for active checkout approvers' do
    sign_in approver

    get "/api/members/#{approver.id}/permissions"

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)['tool_checkouts']).to eq(true)
  end

  it 'limits the checkout roster to approver tools and their prerequisites' do
    tool.update_attributes!(prerequisite_ids: [prereq.id])
    visible_checkout = ToolCheckout.create!(member: member, tool: tool, approved_by: approver)
    prerequisite_checkout = ToolCheckout.create!(member: member, tool: prereq, approved_by: create(:member, :admin))
    ToolCheckout.create!(member: member, tool: other_tool, approved_by: create(:member, :admin))

    sign_in approver
    get '/api/admin/tool_checkouts'

    expect(response).to have_http_status(:ok)
    ids = JSON.parse(response.body).map { |c| c['id'] }
    expect(ids).to contain_exactly(visible_checkout.id.to_s, prerequisite_checkout.id.to_s)
  end

  it 'allows approvers to check out members only on tools in their shops and writes an audit log' do
    sign_in approver

    expect do
      post '/api/admin/tool_checkouts', params: { member_id: member.id.to_s, tool_id: tool.id.to_s }
    end.to change(ToolCheckout, :count).by(1).and change(AuditLog, :count).by(1)

    expect(response).to have_http_status(:ok)
    expect(ToolCheckout.last.approved_by_id).to eq(approver.id)
    expect(AuditLog.last.event_type).to eq('tool_checkout_created')

    post '/api/admin/tool_checkouts', params: { member_id: member.id.to_s, tool_id: other_tool.id.to_s }
    expect(response).to have_http_status(403)
  end

  it 'rejects approver checkout submissions when prerequisites are not met' do
    tool.update_attributes!(prerequisite_ids: [prereq.id])
    sign_in approver

    expect do
      post '/api/admin/tool_checkouts', params: { member_id: member.id.to_s, tool_id: tool.id.to_s }
    end.not_to change(ToolCheckout, :count)

    expect(response).to have_http_status(422)
    expect(JSON.parse(response.body)['unmet_prerequisites']).to eq(['Safety Class'])
  end

  it 'allows privileged users to check out members when prerequisites are not met' do
    admin = create(:member, :admin)
    tool.update_attributes!(prerequisite_ids: [prereq.id])
    sign_in admin

    expect do
      post '/api/admin/tool_checkouts', params: { member_id: member.id.to_s, tool_id: tool.id.to_s }
    end.to change(ToolCheckout, :count).by(1)

    expect(response).to have_http_status(:ok)
  end

  it 'allows approvers to revoke only checkouts they approved and writes an audit log' do
    own_checkout = ToolCheckout.create!(member: member, tool: tool, approved_by: approver)
    other_checkout = ToolCheckout.create!(member: member, tool: Tool.create!(name: 'Lathe', shop: shop), approved_by: create(:member, :admin))

    sign_in approver
    expect do
      delete "/api/admin/tool_checkouts/#{own_checkout.id}", params: { revocation_reason: 'Safety issue' }
    end.to change(AuditLog, :count).by(1)

    expect(response).to have_http_status(:ok)
    expect(own_checkout.reload.revoked_at).to be_present
    expect(AuditLog.last.event_type).to eq('tool_checkout_revoked')

    delete "/api/admin/tool_checkouts/#{other_checkout.id}", params: { revocation_reason: 'Safety issue' }
    expect(response).to have_http_status(403)
    expect(other_checkout.reload.revoked_at).to be_nil
  end
end
