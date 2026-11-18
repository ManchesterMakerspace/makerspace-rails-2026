require 'rails_helper'
RSpec.describe EventbriteIntegration::Backfill do
  let(:client) { instance_double(EventbriteIntegration::Backfill::WaitingClient) }
  let(:sync) { instance_double(EventbriteIntegration::Synchronizer) }
  before do
    allow(EventbriteIntegration::Configuration).to receive(:validate!)
    allow(EventbriteIntegration::Configuration).to receive(:organization_ids).and_return(['org'])
    allow(EventbriteIntegration::Backfill::WaitingClient).to receive(:new).and_return(client)
    allow(EventbriteIntegration::Synchronizer).to receive(:new).and_return(sync)
  end
  it 'does not advance the watermark on failure and resumes the successful page cursor' do
    allow(sync).to receive(:import_attendee)
    allow(client).to receive(:each_page) do |_, _, **options, &block|
      expect(options[:continuation]).to be_nil
      block.call({ 'attendees' => [{ 'id' => 'a' }] }, 'page-2')
      raise EventbriteIntegration::Client::ApiError.new(500, 'ERROR')
    end
    expect { described_class.new('attendees', {}).call }.to raise_error(EventbriteIntegration::Client::ApiError)
    run = EventbriteSyncRun.first
    expect(run.completed_at).to be_nil
    expect(run.progress['org']['cursor']).to eq('page-2')
    allow(client).to receive(:each_page) do |_, _, **options, &block|
      expect(options[:continuation]).to eq('page-2')
      block.call({ 'attendees' => [{ 'id' => 'b' }] }, nil)
    end
    described_class.new('attendees', { 'RESUME_RUN_ID' => run.id.to_s }).call
    expect(run.reload.completed_at).to be_present
    expect(sync).to have_received(:import_attendee).exactly(2).times
  end
  it 'persists sanitized provider diagnostics in the failed run without advancing progress' do
    error = EventbriteIntegration::Client::ApiError.new(400, 'ARGUMENTS_ERROR',
      description: "Invalid 'status': 'both'. https://example.com/private")
    allow(client).to receive(:each_page).and_raise(error)
    expect { described_class.new('orders', {}).call }.to raise_error(error)
    run = EventbriteSyncRun.first
    expect(run.last_error).to include('ARGUMENTS_ERROR', "Invalid 'status': 'both'.")
    expect(run.last_error).not_to include('https://example.com/private')
    expect(run.completed_at).to be_nil
    expect(run.progress).to eq({})
    expect(run.failed).to eq(1)
  end

  it 'backfills refund timestamps from the provider without inventing an import-time refund' do
    allow(EventbriteIntegration::Synchronizer).to receive(:new).and_call_original
    expect(client).to receive(:each_page).with('organizations/org/events/', anything, continuation: nil)
      .and_yield({ 'events' => [{ 'id' => 'event-1', 'organization_id' => 'org', 'status' => 'live' }] }, nil)
    expect(client).to receive(:each_page).with('events/event-1/orders/', anything, continuation: nil)
      .and_yield({ 'orders' => [
        { 'id' => 'dated', 'event_id' => 'event-1', 'status' => 'refunded', 'changed' => '2026-10-03T12:00:00Z' },
        { 'id' => 'unknown', 'event_id' => 'event-1', 'status' => 'refunded' }
      ] }, nil)
    run = described_class.new('orders', {}).call
    expect(run.completed_at).to be_present
    expect(EventbriteOrder.find_by(eventbrite_id: 'dated').refunded_at).to eq(Time.utc(2026, 10, 3, 12))
    unknown = EventbriteOrder.find_by(eventbrite_id: 'unknown')
    expect(unknown.refunded_at).to be_nil
    expect(unknown.invalidated_at).to be_present
  end
  it 'persists rejected-path structure without leaking raw app-generated values' do
    error = EventbriteIntegration::Client::InvalidPathError.new('events/private value/orders/')
    allow(client).to receive(:each_page).and_raise(error)
    expect { described_class.new('orders', {}).call }.to raise_error(error)
    run = EventbriteSyncRun.first
    expect(run.last_error).to include('Invalid API path:', 'shape=events/<invalid bytes=13>/orders/', 'whitespace')
    expect(run.last_error).not_to include('private value')
    expect(run.processed).to eq(0)
    expect(run.completed_at).to be_nil
    expect(run.failed).to eq(1)
  end
  it 'combines literal positive/negative case-insensitive name filters' do
    allow(client).to receive(:each_page).and_yield({ 'events' => [
      { 'id' => '1', 'name' => { 'text' => 'WELDING Basics' } },
      { 'id' => '2', 'name' => { 'text' => 'Advanced Welding' } },
      { 'id' => '3', 'name' => { 'text' => 'Pottery' } }
    ] }, nil)
    event = double('event')
    allow(sync).to receive(:import_event).and_return(event)
    allow(sync).to receive(:tickets)
    run = described_class.new('events', { 'NAME_INCLUDE' => 'welding', 'NAME_EXCLUDE' => 'ADVANCED' }).call
    expect(run.processed).to eq(1)
    expect(run.skipped).to eq(2)
    expect(sync).to have_received(:import_event).once
  end
  it 'requests orders without the rejected status filter and resumes pages with refund expansions intact' do
    event = double(eventbrite_id: 'event-1')
    allow(sync).to receive(:import_event).and_return(event)
    allow(sync).to receive(:import_order)
    allow(client).to receive(:each_page).with('organizations/org/events/', anything, continuation: nil)
      .and_yield({ 'events' => [{ 'id' => 'event-1', 'name' => { 'text' => 'Workshop' } }] }, nil)
    params = { 'expand' => 'attendees,refund_requests' }
    placed = { 'id' => 'placed', 'status' => 'placed', 'attendees' => [] }
    refunded = { 'id' => 'refunded', 'status' => 'refunded', 'refund_requests' => [{ 'items' => [{ 'status' => 'processed' }] }] }
    expect(client).to receive(:each_page).with('events/event-1/orders/', params, continuation: nil) do |_, _, **_, &block|
      block.call({ 'orders' => [placed] }, 'opaque+page/2')
      raise EventbriteIntegration::Client::ApiError.new(503, 'ERROR')
    end
    backfill = described_class.new('orders', {})
    expect { backfill.call }.to raise_error(EventbriteIntegration::Client::ApiError)
    run = backfill.run.reload
    expect(run.completed_at).to be_nil
    expect(run.progress['org']['order_cursor']).to eq('opaque+page/2')
    expect(run.processed).to eq(1)

    expect(client).to receive(:each_page).with('events/event-1/orders/', params, continuation: 'opaque+page/2')
      .and_yield({ 'orders' => [refunded] }, nil)
    described_class.new('orders', { 'RESUME_RUN_ID' => run.id.to_s }).call
    expect(run.reload.completed_at).to be_present
    expect(run.processed).to eq(2)
    expect(run.progress['org']['order_cursor']).to be_nil
    expect(sync).to have_received(:import_order).with(placed).once
    expect(sync).to have_received(:import_order).with(refunded).once
  end

  it 'discards a legacy status-filtered order cursor while preserving the event checkpoint and name filters' do
    run = EventbriteSyncRun.create!(kind: 'orders', organizations: ['org'], filters: { 'NAME_EXCLUDE' => 'open house' },
      progress: { 'org' => { 'cursor' => 'event-page', 'order_cursor' => 'legacy-status-page', 'completed_items' => ['finished'] } })
    allow(sync).to receive(:import_event).and_return(double(eventbrite_id: 'event-1'))
    expect(client).to receive(:each_page).with('organizations/org/events/', anything, continuation: 'event-page')
      .and_yield({ 'events' => [
        { 'id' => 'finished', 'name' => { 'text' => 'Done' } },
        { 'id' => 'excluded', 'name' => { 'text' => 'Open House' } },
        { 'id' => 'event-1', 'name' => { 'text' => 'Workshop' } }
      ] }, nil)
    expect(client).to receive(:each_page).with('events/event-1/orders/', { 'expand' => 'attendees,refund_requests' }, continuation: nil)
      .and_yield({ 'orders' => [] }, nil)
    described_class.new('orders', { 'RESUME_RUN_ID' => run.id.to_s }).call
    expect(run.reload.progress['org']['order_listing_version']).to eq(described_class::ORDER_LISTING_VERSION)
    expect(run.completed_at).to be_present
    expect(run.skipped).to eq(1)
    expect(sync).to have_received(:import_event).once
  end
  it 'restarts an expired continuation with original criteria and preserves a successful watermark' do
    prior = EventbriteSyncRun.create!(kind: 'attendees', organizations: ['org'], started_at: 1.day.ago, completed_at: 23.hours.ago)
    run = EventbriteSyncRun.create!(kind: 'attendees', organizations: ['org'], filters: { 'CHANGED_SINCE' => 'last' }, progress: { 'org' => { 'cursor' => 'expired' } })
    calls = []
    allow(client).to receive(:each_page) do |_, params, **options, &block|
      calls << options[:continuation]
      expect(params['changed_since']).to eq((prior.started_at - 1).utc.iso8601)
      raise EventbriteIntegration::Client::ApiError.new(400, 'BAD_CONTINUATION_TOKEN') if calls.size == 1
      block.call({ 'attendees' => [] }, nil)
    end
    described_class.new('attendees', { 'RESUME_RUN_ID' => run.id.to_s, 'CHANGED_SINCE' => '2000-01-01T00:00:00Z' }).call
    expect(calls).to eq(['expired', nil])
    expect(run.reload.completed_at).to be_present
  end
  it 'rejects non-UTC incremental timestamps without advancing checkpoints' do
    expect(client).not_to receive(:each_page)
    expect { described_class.new('attendees', { 'CHANGED_SINCE' => '2026-01-01T01:00:00+01:00' }).call }.to raise_error(ArgumentError)
    expect(EventbriteSyncRun.first.completed_at).to be_nil
    expect(EventbriteSyncRun.first.failed).to eq(1)
  end

  it 'discovers all organizations across pages when no allowlist is configured' do
    allow(EventbriteIntegration::Configuration).to receive(:organization_ids).and_return([])
    expect(client).to receive(:each_page).with('users/me/organizations/').and_yield(
      { 'organizations' => [{ 'id' => 'org' }] }, 'more-organizations'
    ).and_yield({ 'organizations' => [{ 'id' => 'another-org' }, { 'id' => 'org' }] }, nil)
    %w[org another-org].each do |org|
      expect(client).to receive(:each_page).with("organizations/#{org}/events/", anything, continuation: nil)
        .and_yield({ 'events' => [] }, nil)
    end

    run = described_class.new('events', {}).call
    expect(run.organizations).to match_array(%w[org another-org])
    expect(run.completed_at).to be_present
  end

  it 'resumes the snapshotted organizations without rediscovery when unrestricted' do
    allow(EventbriteIntegration::Configuration).to receive(:organization_ids).and_return([])
    run = EventbriteSyncRun.create!(kind: 'events', organizations: ['past-org'],
      progress: { 'past-org' => { 'cursor' => 'next-page' } })
    expect(client).not_to receive(:each_page).with('users/me/organizations/')
    expect(client).to receive(:each_page).with('organizations/past-org/events/', anything, continuation: 'next-page')
      .and_yield({ 'events' => [] }, nil)

    described_class.new('events', { 'RESUME_RUN_ID' => run.id.to_s }).call
    expect(run.reload.organizations).to eq(['past-org'])
    expect(run.completed_at).to be_present
  end

  it 'refuses to resume a run containing organizations removed from a narrowed allowlist' do
    run = EventbriteSyncRun.create!(kind: 'events', organizations: %w[org another-org])
    expect(client).not_to receive(:each_page)
    expect { described_class.new('events', { 'RESUME_RUN_ID' => run.id.to_s }).call }
      .to raise_error(ArgumentError, 'Resume kind or organization configuration mismatch')
    expect(run.reload.completed_at).to be_nil
    expect(run.failed).to eq(1)
  end

  it 'does not import any organization when discovery fails before completing' do
    allow(EventbriteIntegration::Configuration).to receive(:organization_ids).and_return([])
    expect(client).to receive(:each_page).with('users/me/organizations/') do |_, &block|
      block.call({ 'organizations' => [{ 'id' => 'org' }] }, 'more-organizations')
      raise EventbriteIntegration::Client::ApiError.new(503, 'ERROR')
    end
    expect(sync).not_to receive(:import_event)
    expect { described_class.new('events', {}).call }.to raise_error(EventbriteIntegration::Client::ApiError)
    expect(EventbriteSyncRun.where(:completed_at.ne => nil).count).to eq(0)
  end
end
