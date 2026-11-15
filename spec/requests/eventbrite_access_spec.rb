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

  it 'lets authorized staff browse and filter all imported organizations when unrestricted' do
    allow(EventbriteIntegration::Configuration).to receive(:organization_ids).and_return([])
    order = EventbriteOrder.create!(organization_id: 'another-org', eventbrite_id: '1', name: 'Workshop buyer')
    EventbriteOrder.create!(organization_id: 'org', eventbrite_id: '2', name: 'Other buyer')
    sign_in create(:member, role: 'admin')
    get '/api/admin/eventbrite/orders', params: { organization_id: 'another-org', search: 'Workshop' }
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body).map { |row| row['id'] }).to eq([order.id.to_s])
    get "/api/admin/eventbrite/orders/#{order.id}"
    expect(response).to have_http_status(:ok)
  end

  it 'still denies ordinary members when organization filtering is disabled' do
    allow(EventbriteIntegration::Configuration).to receive(:organization_ids).and_return([])
    sign_in create(:member)
    get '/api/admin/eventbrite/orders'
    expect(response).to have_http_status(:forbidden)
  end

  [['org'], []].each do |organizations|
    context "member order filters with organization allowlist #{organizations.inspect}" do
      before { allow(EventbriteIntegration::Configuration).to receive(:organization_ids).and_return(organizations) }

      it 'intersects member history with filters without returning unrelated orders' do
        subject = create(:member)
        other = create(:member)
        own = EventbriteOrder.create!(organization_id: 'org', eventbrite_id: 'own', name: 'Workshop')
        EventbriteOrder.create!(organization_id: 'org', eventbrite_id: 'other', name: 'Workshop')
        unlinked = EventbriteOrder.create!(organization_id: 'org', eventbrite_id: 'unlinked', name: 'Workshop')
        own_attendee = EventbriteAttendee.create!(organization_id: 'org', eventbrite_id: 'own-attendee', order_id: 'own', member_id: subject.id, link_conflict: true)
        EventbriteAttendee.create!(organization_id: 'org', eventbrite_id: 'other-attendee', order_id: 'other', member_id: other.id, link_conflict: true)
        sign_in create(:member, role: 'board_member')

        [nil, 'linked', 'conflict', 'unlinked'].each do |linked|
          get "/api/admin/members/#{subject.id}/eventbrite/orders", params: { linked: linked, search: 'Workshop' }.compact
          expect(response).to have_http_status(:ok)
          expected = linked == 'unlinked' ? [] : [own.id.to_s]
          expect(JSON.parse(response.body).map { |row| row['id'] }).to eq(expected)
          expect(response.headers['total-items'].to_s).to eq(expected.length.to_s)
        end

        get '/api/admin/eventbrite/orders', params: { linked: 'unlinked' }
        expect(JSON.parse(response.body).map { |row| row['id'] }).to eq([unlinked.id.to_s])

        own_attendee.update!(link_conflict: false)
        get "/api/admin/members/#{subject.id}/eventbrite/orders", params: { linked: 'conflict' }
        expect(JSON.parse(response.body)).to eq([])
      end

      it 'returns no unlinked orders for a member with no linked attendees' do
        subject = create(:member)
        EventbriteOrder.create!(organization_id: 'org', eventbrite_id: 'unrelated')
        sign_in create(:member, role: 'resource_manager')
        get "/api/admin/members/#{subject.id}/eventbrite/orders", params: { linked: 'unlinked' }
        expect(response).to have_http_status(:ok)
        expect(JSON.parse(response.body)).to eq([])
        expect(response.headers['total-items'].to_s).to eq('0')
      end
    end
  end
end
