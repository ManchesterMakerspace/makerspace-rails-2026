module Service
  module SlackUserEvents
    EVENT_TYPES = %w[team_join user_change].freeze

    def self.process(event)
      event = event.to_h.stringify_keys
      return unless EVENT_TYPES.include?(event['type'])

      user = event['user'].to_h.stringify_keys
      return if non_member?(user)

      persist(user)
      welcome(user) if event['type'] == 'team_join'
    rescue => error
      Rails.logger.error("[SlackUserEvent] #{error.class}: #{error.message}")
      Honeybadger.notify(error, context: { slack_event: event }) if defined?(Honeybadger)
      raise
    end

    def self.non_member?(user)
      user['is_bot'] == true || user['deleted'] == true || user['is_app_user'] == true
    end

    def self.persist(user)
      slack_id = user['id'].to_s
      return if slack_id.blank?

      profile = user['profile'].to_h.stringify_keys
      email = profile['email'].to_s.strip.downcase.presence
      member = Member.find_by(email: email) if email
      attributes = {
        slack_email: email && SlackUser.scrub_user_input(email),
        name: SlackUser.scrub_user_input(user['name'].to_s.strip),
        real_name: SlackUser.scrub_user_input((user['real_name'].presence || profile['real_name']).to_s.strip),
        member_id: member&.id
      }.compact

      by_slack = SlackUser.find_by(slack_id: slack_id)
      by_member = SlackUser.find_by(member_id: member.id) if member
      record = by_member || by_slack
      by_slack.destroy! if by_slack && by_member && by_slack.id != by_member.id

      if record
        # SlackUser marks imported identity fields readonly, so event-driven
        # synchronization deliberately writes through the collection.
        SlackUser.collection.find(_id: record.id).update_one(
          '$set' => attributes.merge(slack_id: slack_id)
        )
      else
        SlackUser.create!(attributes.merge(slack_id: slack_id))
      end
    end

    def self.welcome(user)
      name = user['real_name'].presence || user.dig('profile', 'real_name').presence || user['name']
      message = "Welcome to the makerspace #{name}! (<@#{user['id']}>)\n" \
        'This is a good channel to introduce yourself and ask questions.'
      channel = ENV.fetch('SLACK_NEW_MEMBERS_CHANNEL', 'new-members')
      Service::SlackConnector.send_slack_message(message, channel)
    end

    private_class_method :non_member?, :persist, :welcome
  end
end
