require "rails_helper"

RSpec.describe ToolCheckout do
  it "does not rerun revocation cleanup when only the reason changes" do
    checkout = create(:tool_checkout, revoked_at: Time.current)
    allow(CheckoutApproverVolunteering).to receive(:revoke_for!)
    allow(CheckoutApproverCredit).to receive(:reverse!)

    checkout.update!(revocation_reason: "Corrected reason")

    expect(CheckoutApproverVolunteering).not_to have_received(:revoke_for!)
    expect(CheckoutApproverCredit).not_to have_received(:reverse!)
  end

  it "restores the revocation transition when synchronous cleanup fails" do
    checkout = create(:tool_checkout)
    allow(CheckoutApproverVolunteering).to receive(:revoke_for!)
      .and_raise(Error::UnprocessableEntity.new("busy"))

    expect {
      checkout.update!(revoked_at: Time.current)
    }.to raise_error(Error::UnprocessableEntity, "busy")

    expect(checkout.reload.revoked_at).to be_nil
  end
end
