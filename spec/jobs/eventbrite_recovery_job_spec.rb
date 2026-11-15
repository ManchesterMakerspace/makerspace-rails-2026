require 'rails_helper'
RSpec.describe EventbriteRecoveryJob do
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
