class ToolCheckoutNotificationJob < ApplicationJob
  queue_as :slack
  retry_on StandardError, wait: :polynomially_longer, attempts: 5

  def perform(checkout_id, action)
    checkout = ToolCheckout.find_by(id: checkout_id)
    return if checkout.nil?

    case action
    when "created"
      checkout.send_checkout_slack_notification
      checkout.announce_checkout_success
      checkout.invite_member_to_users_channel
    when "revoked"
      checkout.send_revocation_slack_notification
      checkout.remove_member_from_users_channel
    else
      raise ArgumentError, "Unknown checkout notification action: #{action}"
    end
  end
end
