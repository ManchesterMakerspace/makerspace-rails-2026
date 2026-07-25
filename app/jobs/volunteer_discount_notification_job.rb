class VolunteerDiscountNotificationJob < ApplicationJob
  queue_as :integrations
  retry_on StandardError, wait: :polynomially_longer, attempts: 5

  def perform(old_id, new_id, admin_name)
    gateway = Service::BraintreeGateway.connect_gateway
    discounts = gateway.discount.all
    message = "Volunteer discount setting changed by *#{admin_name}*: " \
      "*#{describe(discounts, old_id)}* → *#{describe(discounts, new_id)}*"

    Service::SlackConnector.enque_message(
      message,
      Service::SlackConnector.logs_channel,
      "volunteer-discount/#{old_id}/#{new_id}/logs"
    )
    Service::SlackConnector.enque_message(
      message,
      Service::SlackConnector.treasurer_channel,
      "volunteer-discount/#{old_id}/#{new_id}/treasurer"
    )
  end

  private

  def describe(discounts, discount_id)
    return "No Credit" if discount_id.blank?

    discount = discounts.find { |candidate| candidate.id == discount_id }
    discount&.description.presence || discount&.name.presence || discount_id
  end
end
