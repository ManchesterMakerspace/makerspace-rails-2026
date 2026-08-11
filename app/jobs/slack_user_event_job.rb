class SlackUserEventJob < ApplicationJob
  queue_as :default
  retry_on StandardError, wait: :polynomially_longer, attempts: 5

  def perform(event_id, event)
    Service::SlackUserEvents.process(event, event_id: event_id)
  end
end
