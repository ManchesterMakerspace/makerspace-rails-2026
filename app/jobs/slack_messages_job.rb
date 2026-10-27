class SlackMessagesJob < ApplicationJob
  include Service::SlackConnector
  retry_on StandardError

  queue_as :slack

  def perform(request_id)
    message_payloads = get_enqueued_messages("#{request_id}.*")
    messages_per_channel = message_payloads.group_by { |key, payload| JSON.load(payload)["channel"] }
    messages_per_channel.each do |channel, payloads|
      messages = []
      keys = []
      payloads.sort_by { |key, payload| Time.parse(JSON.load(payload)["timestamp"]) }.each do |key, payload|
        parsed_payload = JSON.load(payload)
        messages.push(parsed_payload["message"])
        keys.push(key)
      end
      # Keys are "<request_id>.<label of the code that queued the message>";
      # the labels tell the audit log which code sent this combined post.
      sources = keys.map { |key| key.to_s.split('.', 2).last }.uniq
      send_slack_messages(messages, channel, source: sources.join(', '))
      REDIS.del(*keys)
    end
  end
end
