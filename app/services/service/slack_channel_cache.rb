module Service
  class SlackChannelCache
    CACHE_PREFIX = "slack:public_channel".freeze
    CACHE_TTL_SECONDS = 1000.hours.to_i
    PAGE_SIZE = 200

    class << self
      def normalize_name(value)
        normalized = value.to_s.strip.sub(/\A#+/, "")
        return normalized if normalized.match?(/\A[CG][A-Z0-9]{8,}\z/)

        normalized.downcase
      end

      def fetch(channel_name)
        name = normalize_name(channel_name)
        return nil if name.blank?

        raw = REDIS.get(cache_key(name))
        raw.present? ? JSON.parse(raw).with_indifferent_access : nil
      rescue Redis::BaseError, JSON::ParserError, TypeError => error
        Rails.logger.warn(
          "[SlackChannelCache] cache read failed name=#{name.inspect} " \
          "error=#{error.class}: #{error.message}"
        )
        nil
      end

      def lookup(channel_name, refresh_on_miss: false)
        name = normalize_name(channel_name)
        return nil if name.blank?

        fetch(name) || (refresh_until(name) if refresh_on_miss)
      end

      def refresh_all!
        scan_public_channels
      end

      def refresh_until(channel_name)
        target = normalize_name(channel_name)
        return nil if target.blank?
        return nil if target.match?(/\A[CG][A-Z0-9]{8,}\z/)

        scan_public_channels(target: target)
      end

      private

      def scan_public_channels(target: nil)
        cursor = nil
        found = nil
        cached_count = 0

        loop do
          response = Service::SlackConnector.with_rate_limit_retry(
            "conversations.list public channel cache"
          ) do
            Service::SlackConnector.client.conversations_list(
              types: "public_channel",
              exclude_archived: true,
              limit: PAGE_SIZE,
              cursor: cursor
            )
          end

          Array(response.channels).each do |channel|
            details = details_for(channel)
            next if details[:name].blank?

            write(details)
            cached_count += 1
            found ||= details.with_indifferent_access if target == details[:name]
          end

          break if found.present?

          cursor = response.response_metadata&.next_cursor.to_s
          break if cursor.blank?
        end

        target ? found : cached_count
      rescue => error
        Rails.logger.warn(
          "[SlackChannelCache] Slack refresh failed target=#{target.inspect} " \
          "error=#{Service::SlackConnector.format_api_error(error)}"
        )
        nil
      end

      def details_for(channel)
        {
          id: channel.id.to_s,
          name: normalize_name(channel.name),
          topic: nested_value(channel, :topic),
          purpose: nested_value(channel, :purpose)
        }
      end

      def nested_value(channel, field)
        value = channel.public_send(field) if channel.respond_to?(field)
        return value.value.to_s if value.respond_to?(:value)
        return value[:value].to_s if value.respond_to?(:[]) && value[:value].present?

        value.to_s
      rescue
        ""
      end

      def write(details)
        REDIS.set(
          cache_key(details[:name]),
          JSON.generate(details),
          ex: CACHE_TTL_SECONDS
        )
      rescue Redis::BaseError => error
        Rails.logger.warn(
          "[SlackChannelCache] cache write failed name=#{details[:name].inspect} " \
          "error=#{error.class}: #{error.message}"
        )
      end

      def cache_key(name)
        "#{CACHE_PREFIX}:#{normalize_name(name)}"
      end
    end
  end
end
