class SlackUserEventJob < ApplicationJob
  queue_as :default

  def perform(event_id, event)
    Service::SlackUserEvents.process(event, event_id: event_id)
  end
end
