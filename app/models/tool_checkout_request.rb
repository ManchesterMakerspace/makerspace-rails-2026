class ToolCheckoutRequest
  include Mongoid::Document
  include SanitizesUserInput
  include ActiveModel::Serializers::JSON

  field :note, type: String
  field :request_date, type: Time, default: -> { Time.now }
  field :status, type: String, default: "open"
  field :message_id, type: String

  belongs_to :member
  belongs_to :tool, optional: true
  belongs_to :tool_group, optional: true
  index({ tool_group_id: 1, status: 1 })
  belongs_to :checked_out, class_name: "ToolCheckout", optional: true

  index({ member_id: 1, status: 1, request_date: 1, _id: 1 })
  index({ tool_id: 1, status: 1, request_date: 1, _id: 1 })

  validates :member, presence: true
  validate :exactly_one_target

  def target
    tool_group || tool
  end

  def exactly_one_target
    errors.add(:base, 'Choose exactly one tool or group') unless [tool_id, tool_group_id].count(&:present?) == 1 && target
  end
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
          request.target.try(:name),
          request.target.try(:shop).try(:name),
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
      request.target.try(:name).to_s.downcase
    when "shopName", "shop_name"
      request.target.try(:shop).try(:name).to_s.downcase
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
    return unless target.announce?

    channel = target.announce_channel.presence || target.shop.try(:slack_channel)
    return if channel.blank?

    message = "*#{member.fullname}* requested checkout on *#{target.name}* in *#{target.shop.try(:name)}*."
    message += "\n> #{note}" if note.present?
    response = ::Service::SlackConnector.send_slack_message(message, channel)
    if response.respond_to?(:ts)
      timestamp = response.ts
      register_announcement(timestamp)
      # A terminal-state notification may already have run while Slack was
      # sending. Preserve whichever announcement was recorded first and bring
      # that message up to date before removing a redundant late post.
      if status == "deleted"
        ::Service::SlackConnector.update_slack_message(channel, message_id,
          "*#{member.fullname}* cancelled their checkout request for *#{target.name}*.")
      elsif status == "closed" && checked_out
        ::Service::SlackConnector.update_slack_message(channel, message_id, checkout_success_message)
      end
      discard_duplicate_announcement(channel, timestamp)
    end
  rescue => e
    Service::ErrorReporter.notify(e)
  end

  def notify_requestor
    return if member.direct_notifications_suppressed?

    slack_id = member.slack_user&.slack_id
    return if slack_id.blank?

    message = "Your checkout request for #{CheckoutDisplay.escape(target.name)} has been created."
    if tool_group
      message += "\nIncluded tools: #{tool_group.included_tools.map { |child| CheckoutDisplay.escape(child.name) }.join(', ')}"
    end
    annotation = target.effective_requestor_annotation
    message += "\n\n*Annotation for requestors*\n#{CheckoutDisplay.escape(annotation)}" if annotation.present?
    Service::SlackConnector.send_slack_message(message, slack_id)
  end

  # Request and approval sends can overlap. Atomically retain the first recorded
  # timestamp; neither path may overwrite a message already owned by the other.
  def register_announcement(timestamp)
    self.class.collection.find(_id: id, "$or" => [{ message_id: nil }, { message_id: "" }])
      .find_one_and_update({ "$set" => { message_id: timestamp } })
    reload
  end

  def discard_duplicate_announcement(channel, timestamp)
    return if message_id.blank? || message_id == timestamp

    ::Service::SlackConnector.delete_slack_message(channel, timestamp)
  end

  def remove_announcement
    return if message_id.blank?

    channel = target.announce_channel.presence || target.shop.try(:slack_channel)
    return if channel.blank?

    ::Service::SlackConnector.update_slack_message(
      channel,
      message_id,
      "*#{member.fullname}* cancelled their checkout request for *#{target.name}*."
    )
  rescue => e
    Service::ErrorReporter.notify(e)
  end

  def checkout_success_message
    return checked_out.checkout_success_message unless tool_group
    "*#{CheckoutDisplay.escape(member.fullname)}* has completed checkout for *#{CheckoutDisplay.escape(tool_group.name)}*: " \
      "#{tool_group.included_tools.map { |child| CheckoutDisplay.escape(child.name) }.join(', ')}."
  end

  def refresh_closed_announcement
    return unless status == 'closed' && message_id.present? && target
    channel = target.announce_channel.presence || target.shop&.slack_channel
    Service::SlackConnector.update_slack_message(channel, message_id, checkout_success_message) if channel.present?
  end
end
