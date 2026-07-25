class ToolCheckoutRequest
  include Mongoid::Document
  include SanitizesUserInput
  include ActiveModel::Serializers::JSON

  field :note, type: String
  field :request_date, type: Time, default: -> { Time.now }
  field :status, type: String, default: "open"
  field :message_id, type: String

  belongs_to :member
  belongs_to :tool
  belongs_to :checked_out, class_name: "ToolCheckout", optional: true

  index({ status: 1, tool_id: 1, member_id: 1, request_date: -1 })
  index({ member_id: 1, status: 1, request_date: -1 })

  validates :member, presence: true
  validates :tool, presence: true
  validates :status, inclusion: { in: %w[open closed deleted] }
  validates :note, length: { maximum: 128 }, allow_blank: true

  after_create { ToolCheckoutRequestNotificationJob.perform_later(id.to_s, "created") }
  after_update :enqueue_cancellation_notification

  def open?
    status == "open"
  end

  def self.table_query(criteria, params)
    rows = criteria.to_a
    search = params[:search].to_s.downcase.strip

    if search.present?
      rows = rows.select do |request|
        [
          request.tool.try(:name),
          request.tool.try(:shop).try(:name),
          request.member.try(:fullname),
          request.member.try(:email),
          request.note
        ].compact.any? { |value| value.to_s.downcase.include?(search) }
      end
    end

    sort_by = params[:order_by].presence || "request_date"
    rows = rows.sort_by { |request| sortable_value_for(request, sort_by) }
    params[:order].to_s.downcase == "desc" ? rows.reverse : rows
  end

  def self.sortable_value_for(request, sort_by)
    case sort_by.to_s
    when "toolName", "tool_name"
      request.tool.try(:name).to_s.downcase
    when "shopName", "shop_name"
      request.tool.try(:shop).try(:name).to_s.downcase
    when "memberName", "member_name"
      request.member.try(:fullname).to_s.downcase
    when "memberEmail", "member_email"
      request.member.try(:email).to_s.downcase
    when "note"
      request.note.to_s.downcase
    else
      request.request_date || Time.at(0)
    end
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

  private

  def enqueue_cancellation_notification
    status_change = previous_changes["status"]
    return unless status_change&.first == "open" && status == "deleted"

    ToolCheckoutRequestNotificationJob.perform_later(id.to_s, "cancelled")
  end
end
