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
end
