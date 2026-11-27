require 'rails_helper'

RSpec.describe 'Public Eventbrite event feed', type: :request do
  around { |example| travel_to(Time.utc(2026, 10, 31, 16)) { example.run } }
  before { allow(EventbriteIntegration::Configuration).to receive(:organization_ids).and_return(['space']) }

  def event(id, **fields)
    EventbriteEvent.create!({ eventbrite_id: id, organization_id: 'space', name: id, listed: true,
      starts_at: 1.hour.from_now, status: 'live' }.merge(fields))
  end

  def ids(**filters)
    get '/eventbrite/events.json', params: filters
    expect(response).to have_http_status(:ok)
    response.parsed_body.pluck('eventbrite_id')
  end

  it 'lists only visible overlapping occurrences, including Open House, in all three formats' do
    event('Open House', starts_at: 2.hours.ago, ends_at: 1.second.from_now)
    event('Future workshop', starts_at: Time.current + 31 * 86_400 - 1)
    event('Just ended', starts_at: 1.hour.ago, ends_at: Time.current)
    event('No end', starts_at: 1.hour.ago)
    event('No start', starts_at: nil, ends_at: 1.hour.from_now)
    event('Cutoff', starts_at: Time.current + 31 * 86_400)
    [{ listed: false }, { restricted: true }, { series_parent: true }, { invalidated_at: Time.current },
      { status: 'draft' }, { status: 'deleted' }, { organization_id: 'other' }].each_with_index { |fields, i| event("hidden-#{i}", **fields) }
    expected = ['Open House', 'Future workshop']
    expect(ids).to eq(expected)
    get '/eventbrite/events', headers: { 'Accept' => 'application/xml' }
    expect(Nokogiri::XML(response.body).xpath('/events/event/eventbrite_id').map(&:text)).to eq(expected)
    get '/eventbrite/events'
    expect(response.media_type).to eq('text/html')
    expect(Nokogiri::HTML(response.body).css('section h2').map(&:text)).to eq(expected)
  end

  it 'combines literal inclusion and exclusion, a rolling cutoff and known inventory' do
    event('A', name: 'Wood [101]', tickets_remaining: 2)
    event('B', name: 'WOOD [101] advanced', tickets_remaining: 3)
    event('C', name: 'wood 1', tickets_remaining: 2)
    event('D', name: 'Wood [101]', tickets_remaining: 1)
    event('E', name: 'Wood [101]', starts_at: 3.days.from_now, tickets_remaining: 2)
    event('F', name: 'Wood [101]')
    event('G', name: 'Wood [101]', tickets_remaining: 0)
    filters = { max_days: 2, name: '[101]', notname: 'ADVANCED' }
    expect(ids(**filters, min_tickets_remaining: 2)).to eq(['A'])
    expect(ids(**filters, min_tickets_remaining: 0)).to eq(%w[A D G])
    expect(ids(**filters)).to eq(%w[A D F G])
    expect(ids(name: 'missing')).to eq([])
  end

  it 'escapes imported display text and omits unsafe links and internal fields' do
    event('entry', name: '<b>Class</b>', summary: '<em>Hello</em>', public_url: 'javascript:alert(1)',
      image_url: 'https://example.org/photo.jpg', slack_receipts: { 'internal' => 'sensitive' })
    get '/eventbrite/events.html'
    expect(response.body).to include('&lt;b&gt;Class&lt;/b&gt;', '&lt;em&gt;Hello&lt;/em&gt;', 'https://example.org/photo.jpg')
    expect(response.body).not_to include('javascript:alert', 'sensitive')
    get '/eventbrite/events.json'
    expect(response.parsed_body.first).to include('public_url' => nil, 'tickets_remaining' => nil)
    expect(response.parsed_body.first.keys).not_to include('slack_receipts', 'organization_id')
  end

  it 'rejects malformed numeric filters in each representation' do
    %w[html json xml].each do |format|
      [{ max_days: 0 }, { max_days: 'abc' }, { min_tickets_remaining: '-1' }, { min_tickets_remaining: '1.5' }].each do |filters|
        get "/eventbrite/events.#{format}", params: filters
        expect(response).to have_http_status(:bad_request)
        expect(response.body).to include(filters.keys.first.to_s)
      end
    end
  end
end
