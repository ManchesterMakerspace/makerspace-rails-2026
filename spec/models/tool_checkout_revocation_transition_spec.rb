require "rails_helper"

RSpec.describe ToolCheckout do
  it "does not rerun revocation cleanup when only the reason changes" do
    checkout = create(:tool_checkout, revoked_at: Time.current)

    expect {
      checkout.update!(revocation_reason: "Corrected reason")
    }.not_to have_enqueued_job(ToolCheckoutRevocationCleanupJob)
  end
end
