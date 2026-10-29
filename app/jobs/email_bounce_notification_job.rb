# Tells people when an email to a member could not be delivered: a Slack DM to
# the member (so they can fix the address) and a message to the member
# relations channel (so the board knows, and knows whether the member was told).
# Enqueued by MailtrapController the first time a failure is recorded for an
# address, so a repeat for the same address does not post again.
class EmailBounceNotificationJob < ApplicationJob
  queue_as :default

  # Failures that mean the address itself is bad. A suspension is a problem on
  # the sending side, so the board hears about it but the member is not asked
  # to change their address.
  MEMBER_NOTICE_EVENTS = %w[bounce reject].freeze
  EVENT_WORDS = {
    "bounce" => "bounced",
    "reject" => "was rejected",
    "suspension" => "was suspended by Mailtrap"
  }.freeze
  SOURCE = "email bounce".freeze

  def perform(event_id)
    event = MailtrapEvent.where(id: event_id).first
    return unless event

    member = Member.where(id: event.member_id).first
    return if member.nil? || member.direct_notifications_suppressed?
    # A failure for an address the member has since replaced is already fixed.
    return unless member.email.to_s.casecmp?(event.email.to_s)

    told = MEMBER_NOTICE_EVENTS.include?(event.event.to_s) && tell_member(member, event)
    tell_board(member, event, told)
  end

  private

  def base_url
    Rails.configuration.x.app_base_url
  end

  def tell_member(member, event)
    slack_user = member.slack_user
    return false unless slack_user && slack_user.invalidated_at.nil? && slack_user.slack_id.present?

    ::Service::SlackConnector.send_slack_message(
      "We couldn't deliver an email to #{event.email}, so you may be missing messages from us such as " \
      "renewal reminders and receipts. If that address is wrong, please update it: " \
      "<#{base_url}/members/#{member.id}|Update your email>",
      slack_user.slack_id,
      source: SOURCE
    )
    true
  rescue StandardError => e
    Rails.logger.error("[EmailBounceNotificationJob] could not message member #{member.id}: #{e.class} #{e.message}")
    false
  end

  def tell_board(member, event, told)
    reason = event.response.to_s.strip.truncate(200)
    outcome = if told
      "They were sent a Slack message asking them to update it."
    elsif MEMBER_NOTICE_EVENTS.include?(event.event.to_s)
      "They have no usable Slack link, so they have not been told. Please contact them another way."
    else
      "The member was not messaged."
    end

    ::Service::SlackConnector.send_slack_message(
      "Email to <#{base_url}/members/#{member.id}|#{member.fullname}> #{EVENT_WORDS.fetch(event.event.to_s, event.event.to_s)} " \
      "(#{event.email})#{reason.present? ? ": #{reason}" : ''}. #{outcome}",
      ::Service::SlackConnector.members_relations_channel,
      source: SOURCE
    )
  end
end
