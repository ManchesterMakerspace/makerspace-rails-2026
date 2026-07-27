class MemberDestroyCleanupJob < ApplicationJob
  include Service::BraintreeGateway

  queue_as :critical
  retry_on StandardError, wait: :polynomially_longer, attempts: 7

  def perform(subscription_id, rental_ids, member_name)
    if subscription_id.present?
      BraintreeService::Subscription.cancel(connect_gateway, subscription_id)
    end
    Rental.where(:id.in => Array(rental_ids)).destroy_all
  rescue => error
    Service::SlackConnector.enque_message(
      "Error cleaning up deleted member #{member_name}: #{error.message}",
      Service::SlackConnector.logs_channel
    )
    raise
  end
end
