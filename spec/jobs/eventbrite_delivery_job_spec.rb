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
end
