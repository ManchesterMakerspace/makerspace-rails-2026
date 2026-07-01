class ToolCheckoutRequest
  include Mongoid::Document
  include ActiveModel::Serializers::JSON

  field :note, type: String
  field :request_date, type: Time, default: -> { Time.now }
  field :status, type: String, default: "open"
  field :message_id, type: String

  belongs_to :member
  belongs_to :tool
  belongs_to :checked_out, class_name: "ToolCheckout", optional: true

  validates :member, presence: true
  validates :tool, presence: true
  validates :status, inclusion: { in: %w[open closed deleted] }
  validates :note, length: { maximum: 128 }, allow_blank: true

  def open?
    status == "open"
  end

  def announce_request
    return unless tool.announce?

    channel = tool.announce_channel.presence || tool.shop.try(:slack_channel)
    return if channel.blank?

    message = "*#{member.fullname}* requested checkout on *#{tool.name}* in *#{tool.shop.try(:name)}*."
    message += "\n> #{note}" if note.present?
    response = ::Service::SlackConnector.send_slack_message(message, channel)
    update_attributes!(message_id: response.ts) if response.respond_to?(:ts)
  rescue => e
    Honeybadger.notify(e) if defined?(Honeybadger)
  end

  def remove_announcement
    return if message_id.blank?

    channel = tool.announce_channel.presence || tool.shop.try(:slack_channel)
    return if channel.blank?

    ::Service::SlackConnector.update_slack_message(
      channel,
      message_id,
      "*#{member.fullname}* cancelled their checkout request for *#{tool.name}*."
    )
  rescue => e
    Honeybadger.notify(e) if defined?(Honeybadger)
  end
end
