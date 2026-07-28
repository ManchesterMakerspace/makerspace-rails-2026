require "rails_helper"

RSpec.describe GoogleResourceSyncJob, type: :job do
  let(:shop) { create(:shop) }

  before do
    allow(Service::GoogleApiErrorReporter)
      .to receive(:report_if_permission_denied)
    allow(Honeybadger).to receive(:notify)
    allow(Rails.logger).to receive(:warn)
  end

  it "propagates synchronization errors for Active Job retry handling" do
    error = StandardError.new("transient directory failure")
    allow(Service::GoogleWorkspace).to receive(:ensure_resource!)
      .and_raise(error)

    expect {
      described_class.new.perform("Shop", shop.id.to_s)
    }.to raise_error(error)
  end

  it "reports permission errors before propagating them" do
    error = StandardError.new("PERMISSION_DENIED: owner access required")
    allow(Service::GoogleWorkspace).to receive(:ensure_resource!)
      .and_raise(error)

    expect {
      described_class.new.perform("Shop", shop.id.to_s)
    }.to raise_error(error)

    expect(Service::GoogleApiErrorReporter)
      .to have_received(:report_if_permission_denied).with(
        error,
        operation: "google_resource_sync_job",
        resource_type: "Shop",
        resource_id: shop.id.to_s
      )
  end

  it "propagates a label failure after ensuring the resource" do
    error = StandardError.new("transient calendar failure")
    allow(Service::GoogleWorkspace).to receive(:ensure_resource!)
    allow(Service::GoogleWorkspace).to receive(:ensure_label!)
      .and_raise(error)

    expect {
      described_class.new.perform("Shop", shop.id.to_s)
    }.to raise_error(error)

    expect(Service::GoogleWorkspace).to have_received(:ensure_resource!)
      .with(shop, "CONFERENCE_ROOM")
    expect(Service::GoogleWorkspace).to have_received(:ensure_label!)
      .with(shop)
  end
end
