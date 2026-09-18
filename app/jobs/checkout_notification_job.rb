class CheckoutNotificationJob < ApplicationJob
  queue_as :slack

  def self.enqueue(action, record_id)
    CheckoutCreation.notify do
      queued = perform_later(action, record_id.to_s)
      raise "Checkout notification enqueue aborted" unless queued
      queued
    end
  end

  def perform(action, record_id)
    CheckoutCreation.notify do
      case action
      when "approval"
        checkout = ToolCheckout.find_by(id: record_id)
        return unless checkout && checkout.member && checkout.tool
        CheckoutCreation.deliver_notifications(checkout, invite: true)
      when "request", "cancellation"
        request = ToolCheckoutRequest.find_by(id: record_id)
        return unless request && request.member && request.tool
        if action == "request" && request.open?
          request.announce_request
        elsif action == "cancellation" && request.status == "deleted"
          request.remove_announcement
        end
      end
    end
  end
end
