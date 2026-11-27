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

  it 'filters each tab by its event title and Eastern start day, including the DST fallback hour' do
    allow(EventbriteIntegration::Configuration).to receive(:organization_ids).and_return([])
    sign_in create(:member, role: 'admin')
    cases = [
      ['org', 'first', Time.utc(2026, 11, 1, 4), 'Workshop'],
      ['org', 'last', Time.utc(2026, 11, 2, 4, 59, 59), 'Late class'],
      ['other', 'first', Time.utc(2026, 11, 1, 6), 'Tours – OPEN HOUSE'],
      ['org', 'past', Time.utc(2026, 11, 1, 3, 59, 59), 'Early'],
      ['org', 'next', Time.utc(2026, 11, 2, 5), 'Tomorrow']
    ]
    cases.each do |org, id, start, title|
      EventbriteEvent.create!(organization_id: org, eventbrite_id: id, name: title, starts_at: start)
      EventbriteOrder.create!(organization_id: org, eventbrite_id: id, event_id: id, name: 'Open House Buyer')
      EventbriteAttendee.create!(organization_id: org, eventbrite_id: id, event_id: id, order_id: id, member_id: BSON::ObjectId.new)
    end
    filters = { from_date: '2026-11-01', to_date: '2026-11-01', exclude_open_house: 'true' }
    %w[events orders attendees].each do |kind|
      path = "/api/admin/eventbrite/#{kind}"
      get path, params: filters.merge(linked: 'linked')
      expect(response.parsed_body.pluck('eventbriteId')).to match_array(%w[first last])
      expect(response.parsed_body.pluck('organizationId').uniq).to eq(['org'])
      expect(response.headers['total-items'].to_s).to eq('2')
      get path, params: filters.merge(pageNum: 1)
      expect(response.parsed_body).to eq([])
      expect(response.headers['total-items'].to_s).to eq('2')
      get path, params: filters.except(:exclude_open_house)
      expect(response.parsed_body.size).to eq(3)
      get path, params: filters.except(:to_date)
      expect(response.parsed_body.pluck('eventbriteId')).to match_array(%w[first last next])
      get path, params: { from_date: '2026-11-02', to_date: '2026-11-01' }
      expect(response).to have_http_status(:bad_request)
    end
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

  it 'keeps absent or malformed member IDs scoped to empty history' do
    viewer = create(:member, role: 'admin')
    EventbriteOrder.create!(organization_id: 'org', eventbrite_id: 'someone-elses-order')
    EventbriteAttendee.create!(organization_id: 'org', eventbrite_id: 'someone-elses-attendee',
      order_id: 'someone-elses-order', member_id: viewer.id)
    sign_in viewer
    [BSON::ObjectId.new.to_s, 'not-a-member-id'].each do |id|
      %w[orders attendees].each do |kind|
        get "/api/admin/members/#{id}/eventbrite/#{kind}"
        expect(response).to have_http_status(:ok)
        expect(JSON.parse(response.body)).to eq([])
        expect(response.headers['total-items'].to_s).to eq('0')
      end
    end
  end

  it 'preserves full-record JSON defaults and relationships through projections and cold or warm metadata caches' do
    member_id = BSON::ObjectId.new
    start = Time.current.change(usec: 123_000)
    event_id, order_id, attendee_id, ticket_id = 4.times.map { BSON::ObjectId.new }
    # Legacy imports can omit fields with model defaults. Read projections must
    # preserve the same JSON as an unprojected document, including those defaults.
    EventbriteEvent.collection.insert_one(_id: event_id, organization_id: 'org', eventbrite_id: 'event',
      name: 'Workshop', starts_at: start, timezone: 'America/New_York', slack_receipts: { private: 'not serialized' })
    EventbriteOrder.collection.insert_one(_id: order_id, organization_id: 'org', eventbrite_id: 'order', event_id: 'event')
    EventbriteAttendee.collection.insert_one(_id: attendee_id, organization_id: 'org', eventbrite_id: 'attendee',
      event_id: 'event', order_id: 'order', ticket_class_id: 'ticket', member_id: member_id)
    EventbriteTicketClass.collection.insert_one(_id: ticket_id, organization_id: 'org', eventbrite_id: 'ticket',
      event_id: 'event', name: 'Admission')
    event, order, attendee, ticket = [EventbriteEvent.find(event_id), EventbriteOrder.find(order_id),
      EventbriteAttendee.find(attendee_id), EventbriteTicketClass.find(ticket_id)]
    sign_in create(:member, role: 'admin')

    { 'events' => [event, 'ticketClasses', [ticket]], 'orders' => [order, 'attendees', [attendee]],
      'attendees' => [attendee, nil, []] }.each do |kind, (record, children_key, children)|
      expected = JSON.parse(EventbriteIntegration::Presenter.call(record).to_json)
      detail = expected.dup
      detail[children_key] = JSON.parse(EventbriteIntegration::Presenter.many(children).to_json) if children_key

      EventbriteIntegration::DisplayCache.invalidate_all
      2.times do
        get "/api/admin/eventbrite/#{kind}"
        expect(response).to have_http_status(:ok)
        expect(JSON.parse(response.body)).to eq([expected])
        expect(response.headers['total-items'].to_s).to eq('1')
      end
      EventbriteIntegration::DisplayCache.invalidate_all
      2.times do
        get "/api/admin/eventbrite/#{kind}/#{record.id}"
        expect(response).to have_http_status(:ok)
        expect(JSON.parse(response.body)).to eq(detail)
      end
    end
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
