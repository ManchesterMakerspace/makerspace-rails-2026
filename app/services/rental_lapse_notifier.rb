# Tells members and staff when a member's membership has ended but they still hold an
# active rental. Messaging only: rentals keep their own subscription and lifecycle, and a
# board member confirms a space is empty before it is rented again (#276). Nothing here
# cancels a rental, changes billing, or frees a space.
#
# Used three ways:
#   notify_event          right away, when an admin revokes or suspends a member or a
#                         membership subscription is cancelled
#   weekly_line / notify_member_weekly
#                         by the Sunday member_review for memberships that lapsed or
#                         were cancelled earlier
#
# Best effort: a failure is logged and never interrupts the revocation, cancellation, or
# review that triggered it.
class RentalLapseNotifier
  WIKI_URL = "https://wiki.manchestermakerspace.org/digital-makerspace/members/rent-a-space#end-a-rental".freeze

  REASONS = {
    expired:   { member: "your membership has expired",                staff: "membership has expired" },
    cancelled: { member: "your membership subscription was cancelled", staff: "membership subscription was cancelled" },
    revoked:   { member: "your membership was revoked",                staff: "membership was revoked" },
    suspended: { member: "your membership was suspended",              staff: "membership was suspended" }
  }.freeze

  # Revoked and suspended members receive no email (ApplicationMailer) and have their Slack
  # access removed, so staff have to reach them another way.
  UNREACHABLE_REASONS = %i[revoked suspended].freeze

  # Rentals that still need the member to act. A vacating rental is already being ended.
  def self.active_rentals(member)
    return [] unless member

    Rental.where(member_id: member.id, status: "active").to_a
  end

  # Why a member's membership counts as ended, for the weekly review.
  def self.reason_for(member)
    return :revoked if member.status == "revoked"
    return :suspended if member.status == "suspended"
    return :expired if member.expirationTime.nil? || member.expirationTime < Time.now.to_i * 1000

    :cancelled
  end

  # "BS-Tote-3 (Black Tote)": the space number plus its description.
  def self.describe(rental)
    detail = rental.description.presence || rental.rental_spot&.description.presence
    detail ? "#{rental.number} (#{detail})" : rental.number.to_s
  end

  # One staff line: "Name's membership has expired, but they still have an active rental: ..."
  def self.staff_text(member, reason, rentals)
    spaces = rentals.map { |rental| describe_with_billing(rental) }.to_sentence
    plural = rentals.size > 1 ? "rentals" : "rental"
    text = "*#{member.fullname}*'s #{REASONS.fetch(reason)[:staff]}, but they still have an active #{plural}: #{spaces}."
    text += " They cannot be notified automatically (email and Slack are off for revoked and suspended members), so please contact them." if UNREACHABLE_REASONS.include?(reason)
    "#{text} <#{profile_url(member)}|View member>"
  end

  def self.weekly_line(member, reason: reason_for(member))
    rentals = active_rentals(member)
    return nil if rentals.empty?

    "• #{staff_text(member, reason, rentals)}"
  end

  # Immediate: staff post in the members relations channel, then the member (Slack DM and
  # email). Returns true when there was a rental to report.
  def self.notify_event(member, reason:)
    rentals = active_rentals(member)
    return false if rentals.empty?

    ::Service::SlackConnector.enque_message(
      "🟠 #{staff_text(member, reason, rentals)}",
      ::Service::SlackConnector.members_relations_channel,
      ::Service::SlackConnector.request_caller_id("rental_lapse.management.#{member.id}.#{reason}")
    )
    deliver_to_member(member, reason, rentals, email: :always)
    true
  rescue => error
    log_failure(member, reason, error)
    false
  end

  # Weekly: the Slack DM when the member has a linked Slack account, otherwise the email, so
  # each member is reached one way per week rather than both.
  def self.notify_member_weekly(member, reason: reason_for(member))
    rentals = active_rentals(member)
    return false if rentals.empty?

    deliver_to_member(member, reason, rentals, email: :if_no_slack)
    true
  rescue => error
    log_failure(member, reason, error)
    false
  end

  def self.member_text(member, reason, rentals)
    spaces = rentals.map { |rental| describe(rental) }.to_sentence
    plural = rentals.size > 1 ? "rentals" : "rental"
    keep = UNREACHABLE_REASONS.include?(reason) ? "" : "If you would rather keep #{rentals.size > 1 ? 'them' : 'it'}, renew your membership first. "
    "Hi #{member.firstname}, #{REASONS.fetch(reason)[:member]}, but you still have an active #{plural}: #{spaces}. " \
      "A rental stays active, and keeps billing, until you cancel it. #{keep}" \
      "To end it, open your profile in the Member Portal (#{profile_url(member)}), go to the Rentals tab, and choose Cancel Rental. " \
      "A board member confirms the space is empty before it can be rented again. " \
      "Step-by-step help: <#{WIKI_URL}|End a rental>"
  end

  def self.profile_url(member)
    "#{Rails.configuration.x.app_base_url}/members/#{member.id}"
  end

  def self.describe_with_billing(rental)
    billing = rental.subscription_id.present? ? " _(still billing)_" : ""
    "#{describe(rental)}#{billing}"
  end

  def self.deliver_to_member(member, reason, rentals, email:)
    return false if UNREACHABLE_REASONS.include?(reason) || member.direct_notifications_suppressed?

    slack_user = SlackUser.find_by(member_id: member.id)
    if slack_user
      ::Service::SlackConnector.enque_message(
        member_text(member, reason, rentals),
        slack_user.slack_id,
        ::Service::SlackConnector.request_caller_id("rental_lapse.member.#{member.id}.#{reason}")
      )
    end
    return true unless email == :always || slack_user.nil?

    RentalMailer.membership_lapsed(member.id.to_s, reason.to_s, rentals.map { |rental| rental.id.to_s }).deliver_later
    true
  end

  def self.log_failure(member, reason, error)
    Rails.logger.error("[RentalLapseNotifier] member_id=#{member&.id} reason=#{reason} #{error.class}: #{error.message}")
  end

  private_class_method :member_text, :describe_with_billing, :deliver_to_member, :log_failure
end
