require "rails_helper"

RSpec.describe CheckoutNotificationJob do
  let(:member) { create(:member, :current) }
  let(:tool) { create(:tool) }

  before { allow(Service::ErrorReporter).to receive(:notify) }

  it "delivers approval side effects in order and keeps audit after a DM failure" do
    actor = create(:member, :current, :admin)
    checkout = ToolCheckout.create!(member: member, tool: tool, approved_by: actor,
      defer_users_channel_invitation: true)
    allow(ToolCheckout).to receive(:find_by).with(id: checkout.id.to_s).and_return(checkout)
    expect(checkout).to receive(:invite_member_to_users_channel).ordered
    expect(checkout).to receive(:send_checkout_slack_notification).ordered.and_raise(StandardError)
    expect(checkout).to receive(:announce_checkout_success).ordered
    expect(Service::AuditLogger).to receive(:log).with(hash_including(resource_id: checkout.id)).ordered
    described_class.perform_now("approval", checkout.id.to_s)
    expect(checkout.reload).to be_persisted
    expect(Service::ErrorReporter).to have_received(:notify)
  end

  it "announces an open request and suppresses an obsolete queued announcement" do
    row = ToolCheckoutRequest.create!(member: member, tool: tool)
    allow(ToolCheckoutRequest).to receive(:find_by).and_return(row)
    expect(row).to receive(:announce_request).once
    described_class.perform_now("request", row.id.to_s)
    row.update!(status: "deleted")
    described_class.perform_now("request", row.id.to_s)
    expect(row).to receive(:remove_announcement)
    described_class.perform_now("cancellation", row.id.to_s)
  end

  it "ignores records deleted before delivery" do
    expect { described_class.perform_now("approval", BSON::ObjectId.new.to_s) }.not_to raise_error
    expect { described_class.perform_now("request", BSON::ObjectId.new.to_s) }.not_to raise_error
  end

  it "still audits a checkout revoked before delivery without inviting or announcing it" do
    checkout = ToolCheckout.create!(member: member, tool: tool, approved_by: create(:member, :current, :admin),
      revoked_at: Time.current, defer_users_channel_invitation: true)
    allow(ToolCheckout).to receive(:find_by).and_return(checkout)
    expect(checkout).not_to receive(:invite_member_to_users_channel)
    expect(checkout).not_to receive(:send_checkout_slack_notification)
    expect(checkout).not_to receive(:announce_checkout_success)
    expect(Service::AuditLogger).to receive(:log).with(hash_including(resource_id: checkout.id))
    described_class.perform_now("approval", checkout.id.to_s)
  end

  it "reports an aborted enqueue without raising" do
    allow(described_class).to receive(:perform_later).and_return(false)
    expect { described_class.enqueue("request", BSON::ObjectId.new) }.not_to raise_error
    expect(Service::ErrorReporter).to have_received(:notify).with("Checkout notification failed", context: { error_class: "RuntimeError" })
  end
end
