require 'rails_helper'

RSpec.describe 'Eventbrite announcement lifecycle' do
  let(:client) { instance_double(EventbriteIntegration::Client) }
  let(:service) { EventbriteIntegration::Announcements.new(client) }
  let(:inventory) { [{ 'id' => 'ticket', 'quantity_total' => 10, 'quantity_sold' => 3 }] }
  let(:payloads) do
    %w[series first second].each_with_index.to_h do |id, index|
      [id, { 'id' => id, 'organization_id' => 'org', 'name' => { 'text' => 'Series' },
        'listed' => true, 'status' => 'live', 'is_series_parent' => id == 'series',
        'series_id' => 'series', 'is_series' => true, 'capacity' => 10,
        'start' => { 'utc' => (index + 1).days.from_now.iso8601, 'timezone' => 'America/New_York' },
        'url' => "https://example.com/#{id}" }]
    end
  end
  before do
    allow(EventbriteIntegration::Configuration).to receive(:organization_ids).and_return(['org'])
    allow(client).to receive(:get) { |path, _| payloads.fetch(path.split('/')[1]) }
    allow(client).to receive(:each_page) do |path, *_, &block|
      body = if path.start_with?('series/', 'organizations/')
        { 'events' => [payloads['second'], payloads['first']] }
      else
        { 'ticket_classes' => inventory }
      end
      block.call(body, nil)
    end
  end

  it 'announces the earliest occurrence once even when the later webhook arrives first' do
    service.webhook({ 'type' => 'event', 'id' => 'second' }, 'event.published')
    service.webhook({ 'type' => 'event', 'id' => 'first' }, 'event.published')
    expect(EventbriteSlackDelivery.count).to eq(1)
    expect(EventbriteSlackDelivery.first.event_ids).to eq(['first'])
    expect(EventbriteEvent.where(eventbrite_id: 'first').first.series_parent).to be(false)
    expect(EventbriteEvent.where(eventbrite_id: 'first').first.tickets_remaining).to eq(7)
  end

  it 'refreshes every saved message for order changes and schedules reconciliation' do
    service.webhook({ 'type' => 'event', 'id' => 'first' }, 'event.published')
    event = EventbriteEvent.where(eventbrite_id: 'first').first
    reminder = service.request(event, 'reminder', %w[first second], day: '2026-11-15')
    EventbriteOrder.create!(organization_id: 'org', eventbrite_id: 'order', event_id: 'first')
    versions = EventbriteSlackDelivery.all.to_h { |delivery| [delivery.id, delivery.revision] }
    inventory.first['quantity_sold'] = 1
    service.webhook({ 'type' => 'order', 'id' => 'order' }, 'order.refunded')
    EventbriteSlackDelivery.all.each { |delivery| expect(delivery.revision).to be > versions.fetch(delivery.id) }
    expect(event.reload.inventory_refresh_at).to be_within(3.seconds).of(5.minutes.from_now)
    expect(reminder.reload.event_ids).to eq(%w[first second])
    expect(event.tickets_sold).to eq(1)
    expect(event.tickets_remaining).to eq(9)
  end

  it 'retains previous totals after a partial inventory fetch fails' do
    event = service.hydrate('first')
    event.update!(tickets_sold: 2, tickets_remaining: 8)
    allow(client).to receive(:each_page) do |_, *_, &block|
      block.call({ 'ticket_classes' => [{ 'id' => 'partial', 'quantity_sold' => 8, 'quantity_total' => 10 }] }, 'next')
      raise EventbriteIntegration::Client::ApiError.new(503, 'UNAVAILABLE')
    end
    expect { service.refresh(event) }.to raise_error(EventbriteIntegration::Client::ApiError)
    expect(event.reload.tickets_sold).to eq(2)
    expect(event.tickets_remaining).to eq(8)
  end

  it 'updates unpublished state without allocating a new publication' do
    service.webhook({ 'type' => 'event', 'id' => 'first' }, 'event.published')
    payloads['first']['status'] = 'draft'
    service.webhook({ 'type' => 'event', 'id' => 'first' }, 'event.unpublished')
    expect(EventbriteSlackDelivery.count).to eq(1)
    expect(EventbriteEvent.where(eventbrite_id: 'first').first.announcement_public?).to be(false)
  end

  it 'updates saved messages on unpublish even when inventory is inaccessible' do
    service.webhook({ 'type' => 'event', 'id' => 'first' }, 'event.published')
    delivery = EventbriteSlackDelivery.first
    delivery.set(ts: '123.456', channel: 'CTEST', due_at: nil, delivered_revision: delivery.revision)
    payloads['first']['status'] = 'draft'
    expect(client).not_to receive(:each_page).with('events/first/ticket_classes/')
    service.webhook({ 'type' => 'event', 'id' => 'first' }, 'event.unpublished')
    expect(delivery.reload.due_at).to be_present
    expect(delivery.revision).to be > delivery.delivered_revision
  end

  it 'unpublishes the whole series without requiring its occurrence listing' do
    service.webhook({ 'type' => 'event', 'id' => 'first' }, 'event.published')
    delivery = EventbriteSlackDelivery.first
    delivery.set(ts: '123.456', channel: 'CTEST', due_at: nil)
    payloads['series']['status'] = 'draft'
    expect(client).not_to receive(:each_page)
    service.webhook({ 'type' => 'event', 'id' => 'series' }, 'event.unpublished')
    expect(delivery.reload.due_at).to be_present
  end

  it 'does not let historical occurrences block a new series announcement' do
    payloads['past'] = payloads['first'].deep_dup.merge('id' => 'past', 'start' => { 'utc' => 1.year.ago.iso8601 })
    allow(client).to receive(:each_page).with('series/series/events/', anything).and_yield({ 'events' => [payloads['past'], payloads['second'], payloads['first']] }, nil)
    expect(client).not_to receive(:each_page).with('events/past/ticket_classes/')
    service.webhook({ 'type' => 'event', 'id' => 'series' }, 'event.published')
    expect(EventbriteSlackDelivery.first.event_ids).to eq(['first'])
  end

  it 'keeps full venue and image details when a duplicate publish lists the series again' do
    allow(client).to receive(:get).with('events/first/', anything).and_return(payloads['first'].merge(
      'venue' => { 'name' => 'Workshop' }, 'logo' => { 'url' => 'https://example.com/image.png' }))
    service.webhook({ 'type' => 'event', 'id' => 'first' }, 'event.published')
    service.webhook({ 'type' => 'event', 'id' => 'second' }, 'event.published')
    event = EventbriteEvent.where(eventbrite_id: 'first').first
    expect(event.venue_label).to eq('Workshop')
    expect(event.image_url).to eq('https://example.com/image.png')
  end

  it 'uses an exclusive rolling cutoff and expands the same daily series reminder' do
    travel_to(Time.utc(2026, 11, 1, 5)) do
      first_run = service.upcoming('3')
      expect(first_run.size).to eq(1)
      expect(first_run.first.event_ids).to eq(['first'])
      wider = service.upcoming('4')
      expect(wider.first.id).to eq(first_run.first.id)
      expect(wider.first.event_ids).to match_array(%w[first second])
      expect(service.upcoming('1')).to eq([])
    end
  end

  it 'does not announce unlisted or restricted events' do
    payloads['first']['listed'] = false
    payloads['second']['invite_only'] = true
    service.webhook({ 'type' => 'event', 'id' => 'series' }, 'event.published')
    expect(EventbriteSlackDelivery.count).to eq(0)
  end

  it 'rechecks the reminder cutoff after fetching current event details' do
    travel_to(Time.utc(2026, 11, 1, 5)) do
      allow(client).to receive(:get).with('events/first/', anything).and_return(payloads['first'].merge('start' => { 'utc' => 10.days.from_now.iso8601 }))
      expect(service.upcoming('3')).to eq([])
    end
  end
end
