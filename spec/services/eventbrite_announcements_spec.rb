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

  it 'removes registration actions for unpublished events and avoids mrkdwn interpretation' do
    event.update!(invalidated_at: Time.current, summary: '<script>test</script>', name: '<!channel>')
    delivery = service.request(event, 'publication', ['one'])
    payload = EventbriteIntegration::AnnouncementMessage.build(delivery, [event])
    expect(payload[:blocks].none? { |block| block[:type] == 'actions' }).to be(true)
    expect(payload[:text]).to include('No longer published')
    expect(payload[:blocks].first[:text][:type]).to eq('plain_text')
  end
end
