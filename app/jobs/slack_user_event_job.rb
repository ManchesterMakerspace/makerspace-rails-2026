class SlackUserEventJob < ApplicationJob
  queue_as :default

  def perform(event)
    Service::SlackUserEvents.process(event)
  end
end
