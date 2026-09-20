require "rails_helper"

RSpec.describe ToolCheckoutRevocationCleanupJob do
  let(:checkout) { create(:tool_checkout, revoked_at: Time.current) }

  it "propagates approver lock contention for Active Job retry handling" do
    error = Error::UnprocessableEntity.new("busy")
    allow(CheckoutApproverVolunteering).to receive(:revoke_for!).and_raise(error)
    allow(CheckoutApproverCredit).to receive(:reverse!)

    expect {
      described_class.new.perform(checkout.id.to_s)
    }.to raise_error(error)
    expect(CheckoutApproverCredit).not_to have_received(:reverse!)
  end

  it "performs both idempotent cleanup steps for a revoked checkout" do
    allow(CheckoutApproverVolunteering).to receive(:revoke_for!)
    allow(CheckoutApproverCredit).to receive(:reverse!)

    described_class.perform_now(checkout.id.to_s)

    expect(CheckoutApproverVolunteering).to have_received(:revoke_for!)
      .with(member_id: checkout.member_id, tool_id: checkout.tool_id)
    expect(CheckoutApproverCredit).to have_received(:reverse!).with(checkout)
  end
end
