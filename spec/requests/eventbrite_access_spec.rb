require 'rails_helper'
RSpec.describe 'Eventbrite staff visibility', type: :request do
  before do
    allow(EventbriteIntegration::Configuration).to receive(:organization_ids).and_return(['org'])
    allow(Service::MemberProvisioning).to receive(:invite_slack)
  end
  %w[admin board_member resource_manager].each do |role|
    it "allows #{role} to read details and linked member history" do
      viewer = create(:member, role: role)
      subject = create(:member)
      order = EventbriteOrder.create!(organization_id: 'org', eventbrite_id: 'order', name: 'Buyer')
      EventbriteAttendee.create!(organization_id: 'org', eventbrite_id: 'attendee', order_id: 'order', member_id: subject.id)
      sign_in viewer
      get "/api/admin/members/#{subject.id}/eventbrite/orders"
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body).map { |row| row['id'] }).to eq([order.id.to_s])
      get "/api/admin/eventbrite/orders/#{order.id}"
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['attendees'].size).to eq(1)
    end
  end
  it 'denies ordinary members access to their own history' do
    member = create(:member)
    sign_in member
    get "/api/admin/members/#{member.id}/eventbrite/attendees"
    expect(response).to have_http_status(:forbidden)
  end
  it 'cannot use filters or search to cross the organization allowlist' do
    EventbriteOrder.create!(organization_id: 'outside', eventbrite_id: '1', name: 'Secret')
    sign_in create(:member, role: 'admin')
    get '/api/admin/eventbrite/orders', params: { search: 'Secret' }
    expect(JSON.parse(response.body)).to eq([])
    get '/api/admin/eventbrite/orders', params: { organization_id: 'outside' }
    expect(response).to have_http_status(:forbidden)
  end
end
