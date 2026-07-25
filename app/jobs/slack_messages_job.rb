class SlackMessagesJob < ApplicationJob
  include Service::SlackConnector
  retry_on StandardError, wait: :polynomially_longer, attempts: 5

  queue_as :slack

  def perform(message_payloads)
    Array(message_payloads)
      .uniq { |payload| payload["dedupe_key"] }
      .group_by { |payload| payload["channel"] }
      .each do |channel, payloads|
        messages = payloads.sort_by { |payload| payload["timestamp"] }.map { |payload| payload["message"] }
        send_slack_messages(messages, channel)
      end
  rescue ActiveJob::DeserializationError
    # A removed source record should not poison the queue.
    nil
  end
end
