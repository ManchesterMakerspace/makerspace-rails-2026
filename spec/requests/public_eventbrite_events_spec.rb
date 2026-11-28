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

  it 'renders a thumbnail beside a linked title and local start time, with provider details only in the feed data' do
    event('1999272400569', name: 'MIG Welding', public_url: 'https://www.eventbrite.com/e/1999272400569',
      image_url: 'https://example.org/photo.jpg', venue_label: 'Workshop 2', ends_at: 4.hours.from_now,
      summary: 'Learn to weld.', timezone: 'America/New_York', tickets_remaining: 1)
    get '/eventbrite/events'
    document = Nokogiri::HTML(response.body)
    expect(document.at_css('title').text).to eq('Upcoming events · Manchester Makerspace')
    expect(document.css('h1').map(&:text)).to eq(['Upcoming events'])
    expect(document.at_css('header > a:has(img[alt="Manchester Makerspace"]) + h1')).to be_present
    row = document.at_css('section.eventbrite-listing')
    link = row.at_css('img + div h2 a')
    expect(link.text).to eq('MIG Welding')
    expect(link['href']).to eq('https://www.eventbrite.com/e/1999272400569')
    expect(link['target']).to eq('_blank')
    expect(link['rel'].split).to include('noopener')
    expect(row.css('a').size).to eq(1)
    time = row.at_css('time')
    expect(time.text).to eq('Oct 31st, 1PM')
    expect(Time.iso8601(time['datetime'])).to eq(1.hour.from_now)
    expect(row.text).to include('Learn to weld.', '1 ticket remaining')
    expect(row.text).not_to include('1999272400569', 'live', 'Workshop 2', 'View event on Eventbrite')
    get '/eventbrite/events.json'
    expect(response.parsed_body.first).to include('eventbrite_id' => '1999272400569', 'venue_label' => 'Workshop 2',
      'status' => 'live', 'ends_at' => 4.hours.from_now.as_json)
  end

  it 'keeps nonzero minutes and uses the event-local date for the ordinal' do
    event('Late workshop', starts_at: Time.utc(2026, 11, 14, 2, 5), timezone: 'America/Los_Angeles')
    get '/eventbrite/events'
    expect(Nokogiri::HTML(response.body).at_css('time').text).to eq('Nov 13th, 6:05PM')
  end

  it 'escapes imported display text and omits unsafe links and internal fields' do
    event('entry', name: '<b>Class</b>', summary: '<em>Hello</em>', public_url: 'javascript:alert(1)',
      image_url: 'https://example.org/photo.jpg', slack_receipts: { 'internal' => 'sensitive' })
    get '/eventbrite/events.html'
    expect(response.body).to include('&lt;b&gt;Class&lt;/b&gt;', '&lt;em&gt;Hello&lt;/em&gt;', 'https://example.org/photo.jpg')
    expect(response.body).not_to include('javascript:alert', 'sensitive')
    expect(Nokogiri::HTML(response.body).at_css('section h2 a')).to be_nil
    get '/eventbrite/events.json'
    expect(response.parsed_body.first).to include('public_url' => nil, 'tickets_remaining' => nil)
    expect(response.parsed_body.first.keys).not_to include('slack_receipts', 'organization_id')
  end

  it 'marks only known zero inventory as sold out in HTML and returns zero in both data feeds' do
    event('full', tickets_remaining: 0)
    event('available', tickets_remaining: 2)
    event('unknown')
    get '/eventbrite/events'
    rows = Nokogiri::HTML(response.body).css('section').index_by { |row| row.at_css('h2').text }
    expect(rows.fetch('full').at_css('.sold-out').text).to eq('SOLD OUT')
    expect(rows.fetch('available').text).to include('2 tickets remaining')
    expect(rows.fetch('unknown').text).to include('Ticket availability unknown')
    expect(response.body.scan('SOLD OUT').size).to eq(1)
    expect(response.body).not_to include('0 tickets remaining')
    get '/eventbrite/events.json', params: { name: 'full' }
    expect(response.parsed_body.first.fetch('tickets_remaining')).to eq(0)
    get '/eventbrite/events.xml', params: { name: 'full' }
    expect(Nokogiri::XML(response.body).at_xpath('/events/event/tickets_remaining').text).to eq('0')
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
