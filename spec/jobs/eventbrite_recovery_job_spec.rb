require 'rails_helper'
RSpec.describe EventbriteRecoveryJob do
  it 'reconciles pending member snapshots without running Member read callbacks' do
    id = BSON::ObjectId.new
    marker = 1.minute.ago
    Member.collection.insert_one(_id: id, email: 'pending@example.com', eventbrite_link_pending_at: marker)
    allow_any_instance_of(Member).to receive(:verify_group_expiry).and_raise('Member callback must not run for the recovery scan')
    described_class.perform_now
    row = Member.collection.find(_id: id).first
    expect(row['eventbrite_link_pending_at']).to be_nil
  end

  it 'dispatches projected IDs for due inventory and Slack work without skipping organization checks' do
    allow(EventbriteIntegration::Configuration).to receive(:organization_ids).and_return(['org'])
    event = EventbriteEvent.create!(organization_id: 'org', eventbrite_id: 'due', inventory_refresh_at: 1.minute.ago)
    EventbriteEvent.create!(organization_id: 'outside', eventbrite_id: 'due', inventory_refresh_at: 1.minute.ago)
    EventbriteEvent.create!(organization_id: 'org', eventbrite_id: 'future', inventory_refresh_at: 1.hour.from_now)
    delivery = EventbriteSlackDelivery.create!(organization_id: 'org', scope_id: 'event', kind: 'publication', mode: Service::SlackConnector.message_destination_mode)
    EventbriteSlackDelivery.create!(organization_id: 'org', scope_id: 'future', kind: 'publication', mode: delivery.mode, due_at: 1.hour.from_now)
    EventbriteSlackDelivery.create!(organization_id: 'outside', scope_id: 'event', kind: 'publication', mode: delivery.mode)
    allow(EventbriteInventoryRefreshJob).to receive(:perform_now)
    allow(EventbriteSlackDeliveryJob).to receive(:perform_now)
    described_class.perform_now
    expect(EventbriteInventoryRefreshJob).to have_received(:perform_now).with(event.id.to_s).once
    expect(EventbriteInventoryRefreshJob).to have_received(:perform_now).once
    expect(EventbriteSlackDeliveryJob).to have_received(:perform_now).with(delivery.id.to_s).once
    expect(EventbriteSlackDeliveryJob).to have_received(:perform_now).once
  end

  it 'recovers only due, unresolved deliveries whose leases expired' do
    due = EventbriteWebhookDelivery.create!(resource: {}, lease_until: 1.minute.ago)
    EventbriteWebhookDelivery.create!(resource: {}, completed_at: Time.current)
    EventbriteWebhookDelivery.create!(resource: {}, failed_at: Time.current)
    EventbriteWebhookDelivery.create!(resource: {}, due_at: 1.hour.from_now)
    EventbriteWebhookDelivery.create!(resource: {}, lease_until: 1.minute.from_now)
    allow(EventbriteDeliveryJob).to receive(:perform_now)
    described_class.perform_now
    expect(EventbriteDeliveryJob).to have_received(:perform_now).with(due.id.to_s).once
    expect(EventbriteDeliveryJob).to have_received(:perform_now).once
  end
end
