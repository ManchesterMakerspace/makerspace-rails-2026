class ToolCheckout
  include Mongoid::Document
  include ActiveModel::Serializers::JSON
  include Service::SlackConnector

  field :checked_out_at, type: Time, default: -> { Time.now }
  field :revoked_at, type: Time
  field :revocation_reason, type: String  # internal only — not shown to member
  field :signed_off_via, type: String, default: "portal"  # "portal" or "slack"

  belongs_to :member
  belongs_to :tool
  belongs_to :approved_by, class_name: "Member", optional: true

  validates :member, presence: true
  validates :tool, presence: true

  after_create :close_open_request, :invite_member_to_users_channel

  def active?
    revoked_at.nil?
  end

  # Notify member via Slack DM when checked out
  def send_checkout_slack_notification
    slack_user = SlackUser.find_by(member_id: self.member_id)
    return if slack_user.nil? || member.direct_notifications_suppressed?

    shop_name = self.tool.shop.try(:name) || "the shop"
    tool_name = self.tool.name
    approver_name = self.approved_by.try(:fullname) || "an admin"
    message = "You have been checked out on *#{tool_name}* in *#{shop_name}* by #{approver_name}. You are now approved to use this tool."
    ::Service::SlackConnector.send_slack_message(message, slack_user.slack_id)
  end

  # Notify member via Slack DM when revoked
  def send_revocation_slack_notification
    slack_user = SlackUser.find_by(member_id: self.member_id)
    return if slack_user.nil? || member.direct_notifications_suppressed?

    shop_name = self.tool.shop.try(:name) || "the shop"
    tool_name = self.tool.name
    message = "Your checkout for *#{tool_name}* in *#{shop_name}* has been revoked. Please contact an admin if you have questions."
    ::Service::SlackConnector.send_slack_message(message, slack_user.slack_id)
  end

  def announce_checkout_success
    request = ToolCheckoutRequest.where(
      member_id: member_id,
      tool_id: tool_id,
      status: "closed",
      checked_out_id: id
    ).first
    announce_channel = tool.announce? ? (tool.announce_channel.presence || tool.shop.try(:slack_channel)) : nil
    channels = [announce_channel, tool.users_channel.presence].compact.uniq
    return if channels.empty?

    message = checkout_success_message
    sent_channels = []
    if announce_channel.present? && request&.message_id.present?
      ::Service::SlackConnector.update_slack_message(announce_channel, request.message_id, message)
      sent_channels << announce_channel
    end

    channels.each do |channel|
      next if sent_channels.include?(channel)

      response = ::Service::SlackConnector.send_slack_message(message, channel)
      request.update_attributes!(message_id: response.ts) if channel == announce_channel && request && response.respond_to?(:ts)
    end
  rescue => e
    Service::ErrorReporter.notify(e)
  end

  def remove_member_from_users_channel
    return if tool.users_channel.blank?

    slack_user = SlackUser.find_by(member_id: member_id)
    return if slack_user.nil?

    ::Service::SlackConnector.kick_from_channel(tool.users_channel, slack_user.slack_id)
  rescue => e
    Service::ErrorReporter.notify(e)
  end

  def checkout_success_message(approved_by: nil)
    slack_id = SlackUser.find_by(member_id: member_id)&.slack_id
    member_reference = slack_id.present? ? "<@#{slack_id}> (#{member.fullname})" : "*#{member.fullname}*"
    approval = approved_by.present? ? " by #{approved_by}" : ''
    message = "#{member_reference} has been checked out on *#{tool.name}* in *#{tool.shop.try(:name)}*#{approval}."
    return message if tool.users_channel.blank?

    users_channel = Service::SlackChannelCache.normalize_name(tool.users_channel)
    if slack_id.blank?
      "#{message}, #{member.fullname} is not yet on Slack, so could not add them to #{users_channel}"
    elsif users_channel_invitation_failed?
      "#{message}, please manually invite <@#{slack_id}> to #{users_channel}"
    else
      message
    end
  end

  def users_channel_invitation_failed?
    @users_channel_invitation_status == :failed
  end

  private

  def close_open_request
    request = ToolCheckoutRequest.where(member_id: member_id, tool_id: tool_id, status: "open").first
    request.update_attributes!(status: "closed", checked_out_id: id) if request
  end

  def invite_member_to_users_channel
    @users_channel_invitation_status = :not_configured
    return if tool.users_channel.blank?

    slack_user = SlackUser.find_by(member_id: member_id)
    if slack_user.nil? || slack_user.slack_id.blank?
      @users_channel_invitation_status = :missing_slack_id
      return
    end

    if ::Service::SlackConnector.channel_member?(tool.users_channel, slack_user.slack_id)
      @users_channel_invitation_status = :already_member
      return
    end

    ::Service::SlackConnector.invite_to_channel(tool.users_channel, slack_user.slack_id)
    @users_channel_invitation_status = :invited
  rescue => e
    begin
      # Some Slack client versions expose the endpoint only through the
      # generated conversations_invite method. Retry it with the bot client
      # before asking a human to add the member manually.
      ::Service::SlackConnector.client.conversations_invite(
        channel: tool.users_channel,
        users: slack_user.slack_id
      )
      @users_channel_invitation_status = :invited
    rescue => fallback_error
      @users_channel_invitation_status = :failed
      Service::ErrorReporter.notify(fallback_error, context: {
        action: 'invite member to tool users channel',
        channel: tool.users_channel,
        slack_id: slack_user&.slack_id,
        initial_error: e.message
      })
    end
  end
end
