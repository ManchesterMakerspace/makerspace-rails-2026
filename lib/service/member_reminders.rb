module Service
  # Two nudges for people who joined the portal but never became members:
  #
  #   fob reminder    - the member has paid but has no fob. Their payment is held until the first
  #                     fob is issued, and the time they paid for starts that day.
  #   signup reminder - the member registered online (status "pending") and has not paid or
  #                     started to pay, and has no fob.
  #
  # Each is switched on separately (SystemConfig FOB_REMINDER_ENABLED / SIGNUP_REMINDER_ENABLED,
  # both off by default) and has one setting, how many days after the first payment / the signup
  # the first email waits (default 7, so it goes out on day 8). Everything else is fixed:
  # exactly two reminders, the second GAP_DAYS after the first, and nothing is sent once
  # CUTOFF_DAYS have passed since the payment / signup.
  #
  # The job runs daily. A reminder that is due or overdue is sent on the next run (so enabling
  # the job late still reaches members inside the cutoff), at most one reminder per member per
  # run, and never a second sooner than GAP_DAYS after the first. These are account emails, not
  # marketing, so they ignore silence_emails. A member with a linked Slack account also gets a
  # matching DM, as the membership expiration notices do.
  module MemberReminders
    ZONE = ActiveSupport::TimeZone['America/New_York'].freeze
    CUTOFF_DAYS = 30
    GAP_DAYS = 14
    MAX_REMINDERS = 2
    MEMBER_STATUSES = Member::ACTIVE_MEMBERSHIP_STATUSES

    class << self
      def run!(at: Time.current)
        sent = { fob: 0, signup: 0 }
        sent[:fob] = run_fob_reminders!(at) if SystemConfig.enabled?(SystemConfig::FOB_REMINDER_ENABLED)
        sent[:signup] = run_signup_reminders!(at) if SystemConfig.enabled?(SystemConfig::SIGNUP_REMINDER_ENABLED)
        sent
      end

      # True when a reminder should go out today. elapsed_days is whole days since the payment or
      # signup; first_wait is the days the first reminder waits (the setting plus one).
      def due?(count:, last_sent_at:, elapsed_days:, first_wait:, today:)
        return false if elapsed_days > CUTOFF_DAYS

        case count.to_i
        when 0
          elapsed_days >= first_wait
        when 1
          elapsed_days >= first_wait + GAP_DAYS &&
            (last_sent_at.nil? || (today - last_sent_at.in_time_zone(ZONE).to_date).to_i >= GAP_DAYS)
        else
          false
        end
      end

      private

      def run_fob_reminders!(at)
        today = at.in_time_zone(ZONE).to_date
        first_wait = SystemConfig.reminder_days(SystemConfig::FOB_REMINDER_DAYS) + 1
        window_start = window_start_time(today)

        recent_ids = Invoice.where(resource_class: 'member', :transaction_id.nin => [nil, ''], :created_at.gte => window_start)
                            .distinct(:resource_id)
        member_ids = recent_ids.filter_map { |id| BSON::ObjectId.from_string(id.to_s) if BSON::ObjectId.legal?(id.to_s) }
        return 0 if member_ids.empty?

        sent = 0
        eligible(Member.where(:id.in => member_ids, :status.in => MEMBER_STATUSES)).each do |member|
          paid = Invoice.where(resource_class: 'member', :resource_id.in => [member.id.to_s],
                               :transaction_id.nin => [nil, '']).to_a
          # A payment that was refunded, or is being refunded, is not a reason to ask for a fob.
          next if paid.all? { |invoice| invoice.refunded || invoice.refund_requested.present? }

          paid_on = paid.map(&:created_at).min.in_time_zone(ZONE).to_date
          next unless due?(count: member.fob_reminder_count, last_sent_at: member.fob_reminder_last_sent_at,
                           elapsed_days: (today - paid_on).to_i, first_wait: first_wait, today: today)

          sent += 1 if notify!(member, :fob, paid_on: paid_on)
        end
        sent
      end

      def run_signup_reminders!(at)
        today = at.in_time_zone(ZONE).to_date
        first_wait = SystemConfig.reminder_days(SystemConfig::SIGNUP_REMINDER_DAYS) + 1
        # Only brand-new registrations (status "pending"), never the older accounts that were
        # created as activeMember before that status existed.
        candidates = eligible(Member.where(status: 'pending', :startDate.gte => window_start_time(today)))

        sent = 0
        candidates.each do |member|
          # Any invoice at all means they have started to pay, so this is no longer an unfinished signup.
          next if Invoice.where(resource_class: 'member', :resource_id.in => [member.id.to_s]).exists?

          signed_up_on = (member.startDate.presence || member.id.generation_time).in_time_zone(ZONE).to_date
          next unless due?(count: member.signup_reminder_count, last_sent_at: member.signup_reminder_last_sent_at,
                           elapsed_days: (today - signed_up_on).to_i, first_wait: first_wait, today: today)

          sent += 1 if notify!(member, :signup)
        end
        sent
      end

      def window_start_time(today)
        (today - CUTOFF_DAYS.days).in_time_zone(ZONE).beginning_of_day
      end

      # Members that could receive either reminder: not the landlord account, an address to send
      # to, no fob, and not earning their membership (that is tracked in its own system).
      def eligible(scope)
        earned_ids = EarnedMembership.where(status: 'active').distinct(:member_id)
        scope.where(:firstname.ne => 'Landlord', :lastname.ne => 'Fob', :id.nin => earned_ids)
             .select { |member| member.email.present? && member.access_cards.none? }
      end

      # Returns true when the email was queued. Failures are reported, never raised, so one bad
      # record cannot stop the rest of the run.
      def notify!(member, kind, paid_on: nil)
        if kind == :fob
          MemberMailer.fob_reminder(member.id.as_json, paid_on.iso8601).deliver_later
          member.set(fob_reminder_count: member.fob_reminder_count.to_i + 1, fob_reminder_last_sent_at: Time.current)
        else
          MemberMailer.signup_reminder(member.id.as_json).deliver_later
          member.set(signup_reminder_count: member.signup_reminder_count.to_i + 1, signup_reminder_last_sent_at: Time.current)
        end
        notify_slack!(member, kind)
        true
      rescue => error
        Service::ErrorReporter.notify(error, context: { member_id: member.id.to_s, reminder: kind.to_s })
        false
      end

      # A bonus channel alongside the email, never a replacement; a Slack failure must not undo or
      # repeat the email, so it is reported on its own.
      def notify_slack!(member, kind)
        slack_id = member.slack_user&.slack_id
        return if slack_id.blank?

        message = if kind == :fob
          "Hi #{member.firstname}, your Manchester Makerspace membership payment is in. Your membership starts the day you " \
            "pick up your key fob, so come to an open house on a Monday from 6 to 8pm and bring a photo ID. " \
            "Schedule: https://manchestermakerspace.org/calendar"
        else
          "Hi #{member.firstname}, you're almost a Manchester Makerspace member. Sign in to the member portal to choose a " \
            "membership, then come to an open house on a Monday from 6 to 8pm for orientation and your key fob. " \
            "Schedule: https://manchestermakerspace.org/calendar"
        end
        Service::SlackConnector.send_slack_message(message, slack_id)
      rescue => error
        Service::ErrorReporter.notify(error, context: { member_id: member.id.to_s, reminder: kind.to_s, channel: 'slack' })
      end
    end
  end
end
