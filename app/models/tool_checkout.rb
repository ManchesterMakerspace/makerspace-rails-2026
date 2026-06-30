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


  after_create :close_open_checkout_request

  def active?
    revoked_at.nil?
  end


  def close_open_checkout_request
    request = ToolCheckoutRequest.where(member_id: member_id, tool_id: tool_id, status: 'open').order_by(created_at: :asc).first
    return unless request

    request.update_attributes!(status: 'closed', checked_out: id)
    announce_checkout_success(request) if tool.announce?
  end

  def announce_checkout_success(request)
    channel = tool.announce_channel.presence || tool.shop.try(:slack_channel)
    message = "*#{member.fullname}* was checked out on *#{tool.name}*."
    if request.message_id.present?
      ::Service::SlackConnector.update_slack_message(message, channel, request.message_id)
    else
      response = ::Service::SlackConnector.send_slack_message(message, channel)
      message_id = response.try(:[], 'ts') || response.try(:[], :ts) || response.try(:ts)
      request.update_attributes!(message_id: message_id) if message_id.present?
    end
  end

  # Notify member via Slack DM when checked out
  def send_checkout_slack_notification
    slack_user = SlackUser.find_by(member_id: self.member_id)
    return if slack_user.nil? || self.member.silence_emails

    shop_name = self.tool.shop.try(:name) || "the shop"
    tool_name = self.tool.name
    approver_name = self.approved_by.try(:fullname) || "an admin"
    message = "You have been checked out on *#{tool_name}* in *#{shop_name}* by #{approver_name}. You are now approved to use this tool."
    ::Service::SlackConnector.send_slack_message(message, slack_user.slack_id)
  end

  # Notify member via Slack DM when revoked
  def send_revocation_slack_notification
    slack_user = SlackUser.find_by(member_id: self.member_id)
    return if slack_user.nil? || self.member.silence_emails

    shop_name = self.tool.shop.try(:name) || "the shop"
    tool_name = self.tool.name
    message = "Your checkout for *#{tool_name}* in *#{shop_name}* has been revoked. Please contact an admin if you have questions."
    ::Service::SlackConnector.send_slack_message(message, slack_user.slack_id)
  end
end
