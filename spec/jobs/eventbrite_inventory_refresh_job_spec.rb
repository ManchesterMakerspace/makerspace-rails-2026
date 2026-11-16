require 'rails_helper'

RSpec.describe EventbriteInventoryRefreshJob do
  let(:event) { EventbriteEvent.create!(organization_id: 'org', eventbrite_id: 'one', inventory_refresh_at: 1.minute.ago) }
  let(:service) { instance_double(EventbriteIntegration::Announcements) }
  before do
    allow(EventbriteIntegration::Configuration).to receive(:organization_allowed?).and_return(true)
    allow(EventbriteIntegration::Announcements).to receive(:new).and_return(service)
  end

  it 'clears completed work but preserves a newer order reconciliation request' do
    allow(service).to receive(:refresh) do
      event.set(inventory_refresh_at: 5.minutes.from_now)
    end
    described_class.perform_now(event.id.to_s)
    expect(event.reload.inventory_refresh_at).to be > Time.current
    event.set(inventory_refresh_at: 1.minute.ago)
    allow(service).to receive(:refresh).and_return(event)
    described_class.perform_now(event.id.to_s)
    expect(event.reload.inventory_refresh_at).to be_nil
  end

  it 'retains durable work during a shared API cooldown' do
    allow(service).to receive(:refresh).and_raise(EventbriteIntegration::Client::Deferred.new(120))
    described_class.perform_now(event.id.to_s)
    expect(event.reload.inventory_refresh_at).to be_within(3.seconds).of(2.minutes.from_now)
  end

  it 'does not fetch organizations removed from the allowlist' do
    allow(EventbriteIntegration::Configuration).to receive(:organization_allowed?).and_return(false)
    expect(service).not_to receive(:refresh)
    described_class.perform_now(event.id.to_s)
  end
end
