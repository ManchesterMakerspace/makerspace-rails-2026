module Service
  module SlackChannelAssignment
    def self.resolve!(channels)
      channels.each_with_object({}) do |(field, value), resolved|
        name = Service::SlackChannelCache.normalize_name(value)
        next if name.blank?

        channel_id = Service::SlackConnector.find_channel_id(name)
        unless channel_id.present?
          raise Error::UnprocessableEntity.new(
            "Slack channel #{display_name(name)} could not be resolved. " \
            "Confirm that the channel exists and that the Member Portal bot can view it."
          )
        end

        resolved[field.to_s] = { id: channel_id, name: name }
      rescue Slack::Web::Api::Errors::SlackError => error
        Rails.logger.warn(
          "[SlackChannelAssignment] resolution failed field=#{field} " \
          "channel=#{name.inspect} error=#{error.class}"
        )
        raise Error::UnprocessableEntity.new(
          "Slack channel #{display_name(name)} could not be resolved because Slack was unavailable. " \
          "Please verify the channel and try again."
        )
      end
    end

    def self.invite_bot_or_notify(resolved_channels, actor)
      return if resolved_channels.blank?

      client = Service::SlackConnector.client
      bot_user_id = client.auth_test.user_id.to_s
      raise 'Slack did not return the bot user ID' if bot_user_id.blank?

      failures = resolved_channels.values.filter_map do |channel|
        begin
          client.conversations_invite(channel: channel[:id], users: bot_user_id)
          nil
        rescue Slack::Web::Api::Errors::AlreadyInChannel
          nil
        rescue => error
          Rails.logger.warn(
            "[SlackChannelAssignment] bot invite failed channel_id=#{channel[:id]} " \
            "error=#{error.class}"
          )
          channel
        end
      end
      notify_actor(failures, actor, bot_user_id) if failures.any?
    rescue => error
      Rails.logger.warn("[SlackChannelAssignment] bot invitation unavailable error=#{error.class}")
      notify_actor(resolved_channels.values, actor, bot_user_id)
    end

    def self.notify_actor(channels, actor, bot_user_id)
      slack_id = actor&.slack_user&.slack_id
      unless slack_id.present?
        Rails.logger.warn(
          "[SlackChannelAssignment] manual invitation reminder could not be delivered " \
          "actor_id=#{actor&.id}"
        )
        return
      end

      mentions = channels.map { |channel| "<##{channel[:id]}>" }.uniq.join(', ')
      bot_reference = bot_user_id.present? ? "<@#{bot_user_id}>" : 'the Member Portal bot'
      Service::SlackConnector.send_slack_message(
        "I could not join #{mentions} automatically. Please manually invite #{bot_reference} " \
        "to #{channels.one? ? 'that channel' : 'those channels'}.",
        slack_id
      )
    rescue => error
      Rails.logger.warn(
        "[SlackChannelAssignment] manual invitation reminder failed " \
        "actor_id=#{actor&.id} error=#{error.class}"
      )
    end

    def self.display_name(name)
      Service::SlackChannelCache.channel_id?(name) ? name : "##{name}"
    end

    private_class_method :notify_actor, :display_name
  end
end
