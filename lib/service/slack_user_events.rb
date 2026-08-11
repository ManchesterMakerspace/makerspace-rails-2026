module Service
  module SlackUserEvents
    EVENT_TYPES = %w[team_join user_change].freeze

    def self.process(event = nil, event_id: nil, **event_keywords)
      event ||= event_keywords
      event = event.to_h.stringify_keys
      return unless EVENT_TYPES.include?(event['type'])

      user = event['user'].to_h.stringify_keys
      if user['deleted'] == true
        invalidate_deleted_user(user, event_id)
        return
      end
      return if non_member?(user)

      persist(user, event_id: event_id)
      welcome(user) if event['type'] == 'team_join'
    rescue => error
      Rails.logger.error("[SlackUserEvent] #{error.class}: #{error.message}")
      Honeybadger.notify(error, context: {
        slack_event_id: event_id.to_s,
        slack_event_type: event['type'].to_s,
        slack_user_id: event.dig('user', 'id').to_s
      }) if defined?(Honeybadger)
      raise
    end

    def self.non_member?(user)
      user['is_bot'] == true || user['is_app_user'] == true
    end

    def self.invalidate_deleted_user(user, event_id)
      slack_id = user['id'].to_s
      return if slack_id.blank?

      record = SlackUser.unscoped.where(slack_id: slack_id).first
      return unless record

      SlackUser.collection.find(_id: record.id).update_one(
        '$set' => {
          invalidated_at: Time.current,
          invalidation_reason: "slack_user_deleted; event_id=#{event_id}"
        }
      )
    end

    def self.persist(user, event_id:)
      slack_id = user['id'].to_s
      return if slack_id.blank?

      profile = user['profile'].to_h.stringify_keys
      email = profile['email'].to_s.strip.downcase.presence
      member = Member.find_by(email: email) if email
      by_slack = SlackUser.unscoped.where(slack_id: slack_id).first
      linked_member = by_slack&.member
      email_mismatch = linked_member && email && normalize_email(linked_member.email) != email
      if email_mismatch
        report_email_mismatch(linked_member, email, slack_id, event_id)
        member = linked_member
      end

      attributes = {
        slack_email: email && SlackUser.scrub_user_input(email),
        name: SlackUser.scrub_user_input(user['name'].to_s.strip),
        real_name: SlackUser.scrub_user_input((user['real_name'].presence || profile['real_name']).to_s.strip),
        member_id: member&.id
      }.compact

      by_member = SlackUser.find_by(member_id: member.id) if member
      record = email_mismatch ? by_slack : (by_member || by_slack)
      by_slack.destroy! if by_slack && by_member && by_slack.id != by_member.id

      if record
        # SlackUser marks imported identity fields readonly, so event-driven
        # synchronization deliberately writes through the collection.
        SlackUser.collection.find(_id: record.id).update_one(
          '$set' => attributes.merge(slack_id: slack_id),
          '$unset' => { invalidated_at: '', invalidation_reason: '' }
        )
      else
        SlackUser.create!(attributes.merge(slack_id: slack_id))
      end
    end

    def self.report_email_mismatch(member, slack_email, slack_id, event_id)
      Service::AuditLogger.log(
        log_type: 'member',
        event_type: 'slack_email_mismatch',
        resource_type: 'Member',
        resource_id: member.id,
        subject: member,
        field_changes: {
          'slack_email' => [normalize_email(member.email), slack_email]
        },
        message_details: "Slack user #{slack_id} changed their Slack email, but the Member record was not changed. " \
          "An admin must reconcile the Member email and Slack email. Slack event ID: #{event_id}.",
        slack_channel: Service::SlackConnector.logs_channel
      )
    end

    def self.normalize_email(email)
      email.to_s.strip.downcase
    end

    def self.welcome(user)
      name = user['real_name'].presence || user.dig('profile', 'real_name').presence || user['name']
      message = "Welcome to the makerspace #{name}! (<@#{user['id']}>)\n" \
        'This is a good channel to introduce yourself and ask questions.'
      channel = ENV.fetch('SLACK_NEW_MEMBERS_CHANNEL', 'new-members')
      Service::SlackConnector.send_slack_message(message, channel)
    end

    private_class_method :non_member?, :invalidate_deleted_user, :persist, :report_email_mismatch,
      :normalize_email, :welcome
  end
end
