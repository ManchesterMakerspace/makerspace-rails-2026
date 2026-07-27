module SlackService
  extend ActiveSupport::Concern
  include Service::SlackConnector

  included do
    after_action :send_messages
  end

  def send_messages
    messages = Array(Current.slack_messages)
    return if messages.empty?

    Current.slack_messages = []
    SlackMessagesJob.perform_later(messages)
  end
end
