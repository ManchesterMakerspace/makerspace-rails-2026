require 'rails_helper'
RSpec.describe EventbriteDeliveryJob do
  let(:delivery) { EventbriteWebhookDelivery.create!(resource: { 'type' => 'order', 'id' => '1' }) }
  let(:sync) { instance_double(EventbriteIntegration::Synchronizer) }
  before { allow(EventbriteIntegration::Synchronizer).to receive(:new).and_return(sync) }
  it 'persists completion and expires only completed work' do
    allow(sync).to receive(:refresh)
    described_class.perform_now(delivery.id.to_s)
    expect(delivery.reload.completed_at).to be_present
    expect(delivery.expires_at).to be_within(2.seconds).of(30.days.from_now)
    expect(delivery.lease_token).to be_nil
    described_class.perform_now(delivery.id.to_s)
    expect(sync).to have_received(:refresh).once
  end
  it 'persists rate-limit deferral without using retry attempts' do
    allow(sync).to receive(:refresh).and_raise(EventbriteIntegration::Client::Deferred.new(120))
    described_class.perform_now(delivery.id.to_s)
    expect(delivery.reload.due_at).to be > 100.seconds.from_now
    expect(delivery.attempts).to eq(0)
    expect(delivery.completed_at).to be_nil
    expect(delivery.expires_at).to be_nil
  end
  it 'recovers an abandoned lease and retains permanent errors' do
    delivery.update!(lease_until: 1.minute.ago, lease_token: 'abandoned')
    allow(sync).to receive(:refresh).and_raise(EventbriteIntegration::Client::ApiError.new(403, 'NOT_AUTHORIZED'))
    described_class.perform_now(delivery.id.to_s)
    expect(delivery.reload.failed_at).to be_present
    expect(delivery.expires_at).to be_nil
    expect(delivery.lease_token).to be_nil
  end
  it 'persists sanitized API descriptions without exposing provider data' do
    error = EventbriteIntegration::Client::ApiError.new(400, 'ARGUMENTS_ERROR',
      description: "Invalid status for 'Private Person' at https://example.com/private")
    allow(sync).to receive(:refresh).and_raise(error)
    described_class.perform_now(delivery.id.to_s)
    expect(delivery.reload.last_error).to include('ARGUMENTS_ERROR', 'Invalid status')
    expect(delivery.last_error).not_to include('Private Person', 'https://example.com/private')
    expect(delivery.failed_at).to be_present
  end
  it 'retains safe rejected-path diagnostics in delivery errors' do
    error = EventbriteIntegration::Client::InvalidPathError.new('events/private value/orders/')
    allow(sync).to receive(:refresh).and_raise(error)
    described_class.perform_now(delivery.id.to_s)
    expect(delivery.reload.last_error).to include('Invalid API path:', 'shape=events/<invalid bytes=13>/orders/')
    expect(delivery.last_error).not_to include('private value')
    expect(delivery.completed_at).to be_nil
  end

  it 'retains reconciliation for the old occurrence when an order is transferred' do
    allow(EventbriteIntegration::Configuration).to receive(:organization_ids).and_return(['org'])
    old_event = EventbriteEvent.create!(organization_id: 'org', eventbrite_id: 'old')
    order = EventbriteOrder.create!(organization_id: 'org', eventbrite_id: '1', event_id: 'old')
    delivery.set(action: 'order.updated')
    announcements = instance_double(EventbriteIntegration::Announcements, webhook: nil, refresh: nil)
    allow(EventbriteIntegration::Announcements).to receive(:new).and_return(announcements)
    allow(sync).to receive(:refresh) { order.set(event_id: 'new') }
    described_class.perform_now(delivery.id.to_s)
    expect(old_event.reload.inventory_refresh_at).to be_within(3.seconds).of(5.minutes.from_now)
    expect(announcements).to have_received(:refresh).with(old_event)
    expect(announcements).to have_received(:webhook).with(delivery.resource, 'order.updated', received_at: delivery.reload.created_at)
    expect(delivery.reload.completed_at).to be_present
  end

  it 'retains the old occurrence refresh even if a transfer fails after saving the order' do
    allow(EventbriteIntegration::Configuration).to receive(:organization_ids).and_return(['org'])
    old_event = EventbriteEvent.create!(organization_id: 'org', eventbrite_id: 'old')
    order = EventbriteOrder.create!(organization_id: 'org', eventbrite_id: '1', event_id: 'old')
    delivery.set(action: 'order.updated')
    allow(sync).to receive(:refresh) do
      order.set(event_id: 'new')
      raise EventbriteIntegration::Client::Deferred.new(30)
    end
    described_class.perform_now(delivery.id.to_s)
    expect(old_event.reload.inventory_refresh_at).to be_within(3.seconds).of(5.minutes.from_now)
    expect(delivery.reload.completed_at).to be_nil
  end
end
