class ToolCheckoutRevocationCleanupJob < ApplicationJob
  retry_on StandardError, wait: :polynomially_longer, attempts: 5

  def perform(checkout_id)
    checkout = ToolCheckout.find_by(id: checkout_id)
    return unless checkout&.revoked_at?

    CheckoutApproverVolunteering.revoke_for!(member_id: checkout.member_id, tool_id: checkout.tool_id)
    CheckoutApproverCredit.reverse!(checkout)
  end
end
