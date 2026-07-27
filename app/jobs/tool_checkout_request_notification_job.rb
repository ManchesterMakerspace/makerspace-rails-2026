class ToolCheckoutRequestNotificationJob < ApplicationJob
  queue_as :slack
  retry_on StandardError, wait: :polynomially_longer, attempts: 5

  def perform(request_id, action)
    request = ToolCheckoutRequest.find_by(id: request_id)
    return if request.nil?

    case action
    when "created"
      request.announce_request if request.status == "open"
    when "cancelled"
      request.remove_announcement
    else
      raise ArgumentError, "Unknown checkout request notification action: #{action}"
    end
  end
end
