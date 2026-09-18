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

  index({ member_id: 1, status: 1, request_date: 1, _id: 1 })
  index({ tool_id: 1, status: 1, request_date: 1, _id: 1 })

  validates :member, presence: true
  validates :tool, presence: true
  validates :status, inclusion: { in: %w[open closed deleted] }
  validates :note, length: { maximum: 128 }, allow_blank: true

  validate :tool_requires_checkout, on: :create

  def tool_requires_checkout
    errors.add(:tool, "No checkout required") if tool&.open
  end

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
    rows = rows.sort_by { |request| [sortable_value_for(request, sort_by), request.id.to_s] }
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
    if response.respond_to?(:ts)
      timestamp = response.ts
      update_attributes!(message_id: timestamp)
      # A terminal-state notification may already have run while Slack was
      # sending, before this timestamp existed. Reconcile this exact message,
      # not a timestamp another worker may have subsequently stored.
      reload
      if status == "deleted"
        ::Service::SlackConnector.update_slack_message(channel, timestamp,
          "*#{member.fullname}* cancelled their checkout request for *#{tool.name}*.")
      elsif status == "closed" && checked_out
        ::Service::SlackConnector.update_slack_message(channel, timestamp, checked_out.checkout_success_message)
      end
    end
  rescue => e
    Service::ErrorReporter.notify(e)
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
    Service::ErrorReporter.notify(e)
  end
end
