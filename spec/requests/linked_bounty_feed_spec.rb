require 'rails_helper'
RSpec.describe 'Linked bounty feed eligibility', type: :request do
  before { allow(Service::MemberProvisioning).to receive(:invite_slack) }
  %w[member admin board_member resource_manager].each do |role|
    it "excludes reporter and unqualified linked tasks for #{role}, preserving ordinary eligibility" do
      member = create(:member, :current, role: role)
      tool = create(:tool, shop: create(:shop))
      own_ticket = create(:fix_ticket, reporter_id: member.id)
      other_ticket = create(:fix_ticket)
      attrs = { title: 'Repair', description: 'Replace switch', credit_value: 1, shop_id: tool.shop_id }
      own = VolunteerTask.create!(**attrs, ticket_id: own_ticket.id)
      linked = VolunteerTask.create!(**attrs, ticket_id: other_ticket.id, prerequisite_tool_ids: [tool.id.to_s])
      ordinary = VolunteerTask.create!(**attrs, prerequisite_tool_ids: [tool.id.to_s])
      sign_in member
      get '/api/volunteer/tasks'
      expect(response).to have_http_status(:ok)
      ids = JSON.parse(response.body).map { |row| row['id'] }
      expect(ids).not_to include(own.id.to_s, linked.id.to_s)
      expect(ids.include?(ordinary.id.to_s)).to eq(role != 'member')
    end
  end
end
