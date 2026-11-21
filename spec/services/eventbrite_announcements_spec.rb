require 'rails_helper'

RSpec.describe EventbriteIntegration::Announcements do
  let(:client) { instance_double(EventbriteIntegration::Client) }
  let(:service) { described_class.new(client) }
  let(:event) { EventbriteEvent.create!(organization_id: 'org', eventbrite_id: 'one', name: 'Welding', status: 'live', listed: true, starts_at: 2.hours.from_now, public_url: 'https://example.com/event') }

  it 'uses shared admission pools once and excludes add-ons' do
    classes = [
      { 'id' => 'a', 'quantity_sold' => 3, 'inventory_tier_id' => 'pool' },
      { 'id' => 'b', 'quantity_sold' => 2, 'inventory_tier_id' => 'pool' },
      { 'id' => 'c', 'quantity_sold' => 10, 'inventory_tier_id' => 'extra' }
    ]
    tiers = [
      { 'id' => 'pool', 'quantity_total' => 12, 'quantity_sold' => 5, 'quantity_pending' => 1, 'count_against_event_capacity' => true },
      { 'id' => 'extra', 'count_against_event_capacity' => false }
    ]
    expect(described_class.totals(classes, tiers, 10)).to eq([5, 4])
  end

  it 'subtracts pending purchases from a custom event capacity across separate pools' do
    classes = [
      { 'id' => 'a', 'quantity_sold' => 3, 'quantity_total' => 20, 'quantity_pending' => 2 },
      { 'id' => 'b', 'quantity_sold' => 2, 'quantity_total' => 20, 'quantity_pending' => 1 }
    ]
    expect(described_class.totals(classes, [], 10)).to eq([5, 2])
  end

  it 'respects ticket-class limits within a larger shared pool' do
    classes = [{ 'id' => 'a', 'inventory_tier_id' => 'pool', 'quantity_sold' => 3, 'quantity_total' => 5 }]
    tiers = [{ 'id' => 'pool', 'quantity_total' => 20, 'quantity_sold' => 3 }]
    expect(described_class.totals(classes, tiers, nil)).to eq([3, 2])
  end

  it 'does not turn malformed pending inventory into available tickets' do
    classes = [{ 'id' => 'a', 'quantity_sold' => 3, 'quantity_total' => 10, 'quantity_pending' => nil }]
    expect(described_class.totals(classes, [], 10)).to eq([3, nil])
  end

  it 'preserves unknown capacity and clamps oversold inventory' do
    expect(described_class.totals([{ 'id' => 'a', 'quantity_sold' => 3 }], [], nil)).to eq([3, nil])
    expect(described_class.totals([{ 'id' => 'a', 'quantity_sold' => 3, 'quantity_total' => 2 }], [], 2)).to eq([3, 0])
  end

  it 'unions same-day reminders while keeping publication anchored' do
    first = service.request(event, 'reminder', ['one'], day: '2026-11-15')
    again = service.request(event, 'reminder', ['two'], day: '2026-11-15')
    expect(again.id).to eq(first.id)
    expect(again.event_ids).to eq(%w[one two])
    expect(service.request(event, 'reminder', ['two'], day: '2026-11-16').id).not_to eq(first.id)
    publication = service.request(event, 'publication', ['one'])
    publication.set(ts: '123.456')
    expect(service.request(event, 'publication', ['two']).event_ids).to eq(['one'])
    expect(publication.kind).to eq('publication')
  end

  it 'rejects invalid windows without calling Eventbrite' do
    expect(client).not_to receive(:get)
    %w[0 -1 1.5 nope].each { |days| expect { service.upcoming(days) }.to raise_error(ArgumentError) }
  end

  it 'does not retarget a publication while its first Slack post is in flight' do
    publication = service.request(event, 'publication', ['one'])
    EventbriteIntegration::Lease.with("slack-delivery:#{publication.id}") do
      expect { service.request(event, 'publication', ['two']) }.to raise_error(EventbriteIntegration::Client::Deferred)
      expect(publication.reload.event_ids).to eq(['one'])
      publication.set(ts: '123.456', channel: 'CTEST')
    end
    expect(service.request(event, 'publication', ['two']).event_ids).to eq(['one'])
  end

  it 'preserves a scheduled Slack retry when duplicate webhooks dirty the message' do
    publication = service.request(event, 'publication', ['one'])
    retry_at = 2.minutes.from_now
    publication.set(due_at: retry_at)
    service.request(event, 'publication', ['one'])
    expect(publication.reload.due_at).to be_within(0.001).of(retry_at)
  end

  it 'dirties matching deliveries in bulk without overriding failures or future retry deadlines' do
    now = Time.current
    mode = Service::SlackConnector.message_destination_mode
    base = { organization_id: event.organization_id, event_ids: [event.eventbrite_id], kind: 'reminder', mode: mode }
    ready = EventbriteSlackDelivery.create!(base.merge(scope_id: 'ready', due_at: nil, revision: 3))
    delayed = EventbriteSlackDelivery.create!(base.merge(scope_id: 'delayed', due_at: now + 2.minutes))
    failed = EventbriteSlackDelivery.create!(base.merge(scope_id: 'failed', due_at: nil, failed_at: now))
    unrelated = EventbriteSlackDelivery.create!(base.merge(organization_id: 'outside', scope_id: 'other'))
    service.send(:dirty_event, event)
    expect(ready.reload.revision).to eq(4)
    expect(ready.due_at).to be >= now
    expect(delayed.reload.revision).to eq(1)
    expect(delayed.due_at).to be_within(0.001).of(now + 2.minutes)
    expect(failed.reload.revision).to eq(1)
    expect(failed.due_at).to be_nil
    expect(failed.failed_at).to be_within(0.001).of(now)
    expect(unrelated.reload.revision).to eq(0)
  end

  it 'removes registration actions for unpublished events and avoids mrkdwn interpretation' do
    event.update!(invalidated_at: Time.current, summary: '<script>test</script>', name: '<!channel>')
    delivery = service.request(event, 'publication', ['one'])
    payload = EventbriteIntegration::AnnouncementMessage.build(delivery, [event])
    expect(payload[:blocks].none? { |block| block[:type] == 'actions' }).to be(true)
    expect(payload[:text]).to include('No longer published')
    expect(payload[:blocks].first[:text][:type]).to eq('plain_text')
  end

  it 'shows a known sold count when remaining capacity is unavailable' do
    event.set(tickets_sold: 3, tickets_remaining: nil)
    publication = service.request(event, 'publication', ['one'])
    payload = EventbriteIntegration::AnnouncementMessage.build(publication, [event])
    expect(payload[:text]).to include('3 sold · Remaining count unavailable')
    expect(payload[:text].scan('New event: Welding').size).to eq(1)
  end

  it 'annotates future ticket sales in the event timezone and removes the notice once sales open' do
    travel_to(Time.utc(2026, 11, 16, 12)) do
      opening = Time.utc(2026, 11, 17, 15)
      event.set(timezone: 'America/New_York', ticket_sales_start_at: opening)
      publication = service.request(event, 'publication', ['one'])
      message = EventbriteIntegration::AnnouncementMessage
      expect(message.build(publication, [event])[:text]).to include('Tickets go on sale Tue, Nov 17, 2026 at 10:00 AM EST')
      event.set(invalidated_at: Time.current)
      expect(message.build(publication, [event])[:text]).not_to include('Tickets go on sale')
      event.set(invalidated_at: nil)
      travel_to(opening)
      expect(message.build(publication, [event])[:text]).not_to include('Tickets go on sale')
    end
  end

  it 'adds the encoded member discount to matching event and series links without losing query strings or fragments' do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('EVENTBRITE_MEMBER_DISCOUNT_CODE').and_return('Members & friends/+')
    event.set(has_member_ticket_class: true, public_url: 'https://www.eventbrite.com/e/one?aff=slack&discount=old#tickets')
    events = [event] + (2..21).map do |id|
      EventbriteEvent.new(organization_id: 'org', eventbrite_id: id.to_s, name: 'Another date', status: 'live',
        listed: true, starts_at: id.days.from_now, public_url: "https://www.eventbrite.com/e/#{id}")
    end
    publication = service.request(event, 'publication', ['one'])
    payload = EventbriteIntegration::AnnouncementMessage.build(publication, events, series_url: 'https://www.eventbrite.com/e/series?aff=slack#dates')
    urls = payload[:blocks].select { |block| block[:type] == 'actions' }.flat_map { |block| block[:elements].map { |element| element[:url] } }
    expect(urls.first).to eq('https://www.eventbrite.com/e/one?aff=slack&discount=Members+%26+friends%2F%2B#tickets')
    expect(urls[1]).to eq('https://www.eventbrite.com/e/2')
    expect(urls.last).to eq('https://www.eventbrite.com/e/series?aff=slack&discount=Members+%26+friends%2F%2B#dates')
    expect(event.public_url).to include('discount=old')
  end

  it 'leaves event links unchanged when the discount code is missing or blank' do
    event.set(has_member_ticket_class: true)
    publication = service.request(event, 'publication', ['one'])
    allow(ENV).to receive(:[]).and_call_original
    [nil, '', '  '].each do |code|
      allow(ENV).to receive(:[]).with('EVENTBRITE_MEMBER_DISCOUNT_CODE').and_return(code)
      payload = EventbriteIntegration::AnnouncementMessage.build(publication, [event])
      expect(payload[:blocks].find { |block| block[:type] == 'actions' }[:elements].first[:url]).to eq(event.public_url)
    end
  end
end
