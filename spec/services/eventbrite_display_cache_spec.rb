require 'rails_helper'

RSpec.describe EventbriteIntegration::DisplayCache do
  def event(attributes = {})
    EventbriteEvent.create!({ organization_id: 'org', eventbrite_id: 'event', name: 'Workshop',
      starts_at: 2.days.from_now.change(usec: 0), timezone: 'America/New_York', listed: true,
      series_parent: false, status: 'live' }.merge(attributes))
  end

  def ticket(attributes = {})
    EventbriteTicketClass.create!({ organization_id: 'org', eventbrite_id: 'ticket', name: 'Admission' }.merge(attributes))
  end

  def data_key(kind, identity)
    described_class.send(:data_key, kind, identity)
  end

  before { allow(EventbriteIntegration::Configuration).to receive(:organization_ids).and_return([]) }

  it 'batches projected metadata, distinguishes organizations and caches missing records' do
    first = event
    second = event(organization_id: 'other', name: 'Other workshop')
    admission = ticket
    pairs = [['org', 'event'], ['other', 'event'], ['org', 'missing']]
    result = described_class.fetch_events(pairs)
    expect(result).to eq(
      pairs[0] => { 'name' => first.name, 'starts_at' => first.starts_at, 'timezone' => first.timezone },
      pairs[1] => { 'name' => second.name, 'starts_at' => second.starts_at, 'timezone' => second.timezone },
      pairs[2] => nil)
    expect(described_class.fetch_ticket_classes([['org', 'ticket']])).to eq(['org', 'ticket'] => { 'name' => admission.name })
    expect(EventbriteEvent).not_to receive(:where)
    expect(EventbriteTicketClass).not_to receive(:where)
    expect(described_class.fetch_events(pairs)).to eq(result)
    expect(described_class.fetch_ticket_classes([['org', 'ticket']])).to eq(['org', 'ticket'] => { 'name' => admission.name })
  end

  it 'invalidates normal save and destroy changes and repairs negative entries on creation' do
    expect(described_class.fetch_events([['org', 'event']])).to eq(['org', 'event'] => nil)
    record = event
    expect(described_class.fetch_events([['org', 'event']]).values.first['name']).to eq('Workshop')
    record.update!(name: 'Renamed')
    expect(described_class.fetch_events([['org', 'event']]).values.first['name']).to eq('Renamed')
    record.destroy!
    expect(described_class.fetch_events([['org', 'event']])).to eq(['org', 'event'] => nil)

    admission = ticket
    described_class.fetch_ticket_classes([['org', 'ticket']])
    admission.update!(name: 'Members')
    expect(described_class.fetch_ticket_classes([['org', 'ticket']]).values.first['name']).to eq('Members')
    admission.destroy!
    expect(described_class.fetch_ticket_classes([['org', 'ticket']])).to eq(['org', 'ticket'] => nil)
  end

  it 'does not invalidate metadata or signup choices for receipt, inventory, and sync bookkeeping' do
    record = event
    described_class.fetch_events([['org', 'event']])
    described_class.signup_choices
    tokens = %i[events signup].map { |kind| REDIS.get(described_class.generation_key(kind)) }
    record.update!(synced_at: Time.current, tickets_sold: 3, inventory_refresh_at: Time.current,
      slack_receipts: { 'receipt' => { 'ts' => '1' } })
    expect(%i[events signup].map { |kind| REDIS.get(described_class.generation_key(kind)) }).to eq(tokens)
  end

  it 'expires metadata after five minutes without extending TTL on reads' do
    event
    described_class.fetch_events([['org', 'event']])
    key = data_key(:events, ['org', 'event'])
    expect(REDIS.ttl(key)).to be_between(298, 300)
    REDIS.expire(key, 30)
    described_class.fetch_events([['org', 'event']])
    expect(REDIS.ttl(key)).to be <= 30
  end

  it 'rejects an old fill after invalidation and an already expired fill' do
    record = event
    old = described_class.fetch_events([['org', 'event']]).values.first
    token = REDIS.get(described_class.generation_key(:events))
    key = data_key(:events, ['org', 'event'])
    record.update!(name: 'After')
    expect(described_class.send(:publish, :events, token, { key => old }, Time.current.to_f + 300)).to be(false)
    expect(described_class.fetch_events([['org', 'event']]).values.first['name']).to eq('After')
    token = REDIS.get(described_class.generation_key(:events))
    expect(described_class.send(:publish, :events, token, { key => old }, Time.current.to_f - 1)).to be(false)
  end

  it 'falls back on Redis read/write failures without failing persisted changes' do
    record = event
    allow(REDIS).to receive(:eval).and_raise(Redis::CannotConnectError)
    allow(REDIS).to receive(:set).and_raise(Redis::CannotConnectError)
    expect { record.update!(name: 'Still saved') }.not_to raise_error
    expect(described_class.fetch_events([['org', 'event']]).values.first['name']).to eq('Still saved')
    expect(described_class.signup_choices.first['name']).to eq('Still saved')
  end

  it 'falls back to projected MongoDB reads when the atomic Redis read fails' do
    event
    described_class.fetch_events([['org', 'event']])
    described_class.signup_choices
    allow(REDIS).to receive(:eval).and_call_original
    allow(REDIS).to receive(:eval).with(described_class::READ, any_args).and_raise(Redis::CannotConnectError)
    allow(EventbriteEvent).to receive(:where).and_call_original
    expect(EventbriteEvent).to receive(:where).with('$or' => [{ organization_id: 'org', eventbrite_id: 'event' }]).once.and_call_original
    expect(EventbriteEvent).to receive(:signup_choices).once.and_call_original
    expect(described_class.fetch_events([['org', 'event']]).values.first['name']).to eq('Workshop')
    expect(described_class.signup_choices.first['name']).to eq('Workshop')
  end

  it 'reads each warm category in one Redis roundtrip without separate generation or payload commands' do
    event
    ticket
    described_class.fetch_events([['org', 'event']])
    described_class.fetch_ticket_classes([['org', 'ticket']])
    described_class.signup_choices
    expect(REDIS).not_to receive(:get)
    expect(REDIS).not_to receive(:mget)
    expect(REDIS).to receive(:eval).with(described_class::READ, any_args).exactly(3).times.and_call_original
    described_class.fetch_events([['org', 'event']])
    described_class.fetch_ticket_classes([['org', 'ticket']])
    described_class.signup_choices
  end

  it 'initializes a lost generation without accepting older fixed-key payloads or shifting missing values' do
    event
    pairs = [['org', 'missing'], ['org', 'event']]
    result = described_class.fetch_events(pairs)
    old_token = REDIS.get(described_class.generation_key(:events))
    REDIS.del(described_class.generation_key(:events))
    expect(EventbriteEvent).to receive(:where).once.and_call_original
    expect(described_class.fetch_events(pairs)).to eq(result)
    expect(REDIS.get(described_class.generation_key(:events))).not_to eq(old_token)
    expect(result[pairs.first]).to be_nil
    expect(result[pairs.last]['name']).to eq('Workshop')
  end

  it 'bounds stale display data by the original deadline when successful writes cannot invalidate Redis' do
    record = event
    described_class.fetch_events([['org', 'event']])
    described_class.signup_choices
    metadata_key = data_key(:events, ['org', 'event'])
    day = Time.current.in_time_zone('America/New_York').to_date.iso8601
    choices_key = data_key(:signup, day)
    deadlines = [metadata_key, choices_key].map { |key| JSON.parse(REDIS.get(key))['expires_at'] }
    allow(REDIS).to receive(:set).and_raise(Redis::CannotConnectError)
    expect { record.update!(name: 'Persisted change') }.not_to raise_error
    expect(described_class.fetch_events([['org', 'event']]).values.first['name']).to eq('Workshop')
    expect(described_class.signup_choices.first['name']).to eq('Workshop')
    expect(REDIS.ttl(metadata_key)).to be_between(1, described_class::TTL)
    expect([metadata_key, choices_key].map { |key| JSON.parse(REDIS.get(key))['expires_at'] }).to eq(deadlines)

    # Redis's real clock has not advanced: the payload deadline must also be
    # checked, rather than relying exclusively on server-side key expiration.
    travel_to Time.at(deadlines.max + 1) do
      expect(described_class.fetch_events([['org', 'event']]).values.first['name']).to eq('Persisted change')
      expect(described_class.signup_choices.first['name']).to eq('Persisted change')
    end
  end

  it 'fences a slow MongoDB fill when a semantic update commits before publication' do
    record = event
    publications = []
    changed = false
    allow(described_class).to receive(:publish).and_wrap_original do |original, *arguments|
      unless changed
        changed = true
        record.update!(name: 'Concurrent change')
      end
      publications << original.call(*arguments)
      publications.last
    end
    # The already-running read may finish with its captured data, but must not
    # publish it as a current snapshot for subsequent callers.
    expect(described_class.fetch_events([['org', 'event']]).values.first['name']).to eq('Workshop')
    expect(publications).to eq([false])
    expect(described_class.fetch_events([['org', 'event']]).values.first['name']).to eq('Concurrent change')
    expect(publications).to eq([false, true])
  end

  it 'replaces malformed metadata rather than serving invalid values' do
    event
    described_class.fetch_events([['org', 'event']])
    key = data_key(:events, ['org', 'event'])
    envelope = { version: described_class::VERSION, generation: REDIS.get(described_class.generation_key(:events)),
      expires_at: 10.minutes.from_now.to_f }
    ['broken', '{}', envelope.merge(entry: false).to_json,
      envelope.merge(entry: { name: 'Private', secret: 'hidden' }).to_json].each do |raw|
      REDIS.set(key, raw)
      expect(described_class.fetch_events([['org', 'event']]).values.first['name']).to eq('Workshop')
    end
  end

  it 'invalidates callback-bypassing changes even after a partially failed batch' do
    record = event
    admission = ticket
    described_class.signup_choices
    described_class.fetch_events([['org', 'event']])
    described_class.fetch_ticket_classes([['org', 'ticket']])
    expect do
      described_class.with_event_changes do
        EventbriteEvent.where(id: record.id).update_all(name: 'Imported')
        raise 'partly failed'
      end
    end.to raise_error('partly failed')
    expect(described_class.signup_choices.first['name']).to eq('Imported')
    expect(described_class.fetch_events([['org', 'event']]).values.first['name']).to eq('Imported')
    described_class.with_ticket_class_changes([]) do
      EventbriteTicketClass.where(id: admission.id).update_all(name: 'Imported admission')
    end
    expect(described_class.fetch_ticket_classes([['org', 'ticket']]).values.first['name']).to eq('Imported admission')
  end

  it 'isolates cached rows by database and organization configuration' do
    event
    described_class.fetch_events([['org', 'event']])
    original = data_key(:events, ['org', 'event'])
    allow(EventbriteIntegration::Configuration).to receive(:organization_ids).and_return(['org'])
    expect(data_key(:events, ['org', 'event'])).not_to eq(original)
    allow(EventbriteEvent).to receive(:collection).and_return(double(database: double(name: 'other_test_database')))
    expect(described_class.generation_key(:events)).to include('other_test_database')
  end

  it 'caches empty signup choices' do
    expect(described_class.signup_choices).to eq([])
    expect(EventbriteEvent).not_to receive(:signup_choices)
    expect(described_class.signup_choices).to eq([])
  end

  it 'invalidates signup choices when listing eligibility changes' do
    record = event
    expect(described_class.signup_choices.map { |row| row['id'] }).to eq([record.id.to_s])
    record.update!(listed: false)
    expect(described_class.signup_choices).to eq([])
    record.update!(listed: true)
    expect(described_class.signup_choices.map { |row| row['id'] }).to eq([record.id.to_s])
    record.update!(name: 'Monthly Open House')
    expect(described_class.signup_choices).to eq([])
  end

  it 'expires signup choices at Eastern midnight so the moving date window advances' do
    zone = ActiveSupport::TimeZone['America/New_York']
    day = Time.current.in_time_zone(zone).to_date
    following = day + 1.day
    start = zone.local(day.year, day.month, day.day, 23, 59, 29)
    travel_to(start) do
      record = event
      expect(described_class.signup_choices.map { |row| row['id'] }).to include(record.id.to_s)
      payload = JSON.parse(REDIS.get(data_key(:signup, day.iso8601)))
      expect(payload['expires_at']).to eq(zone.local(following.year, following.month, following.day).to_f)
    end
    travel_to(start + 32.seconds) do
      expect(EventbriteEvent).to receive(:signup_choices).and_call_original
      expect(described_class.signup_choices).not_to be_empty
    end
  end
end
