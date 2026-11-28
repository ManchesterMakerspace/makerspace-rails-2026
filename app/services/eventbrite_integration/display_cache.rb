require 'digest'

module EventbriteIntegration
  # Display data only. Authorization, signup validation and delivery state stay live.
  class DisplayCache
    TTL = 300
    VERSION = 3
    CACHE_ERRORS = [Redis::BaseError, IOError, SystemCallError].freeze
    READ = <<~LUA.freeze
      local token = redis.call('GET', KEYS[1])
      if not token then
        token = ARGV[1]
        redis.call('SET', KEYS[1], token)
      end
      local values = redis.call('MGET', unpack(KEYS, 2))
      local result = { token }
      for index = 1, #values do
        result[index + 1] = values[index]
      end
      return result
    LUA
    PUBLISH = <<~LUA.freeze
      if redis.call('GET', KEYS[1]) ~= ARGV[1] then return 0 end
      local now = redis.call('TIME')
      local remaining = tonumber(ARGV[2]) - (tonumber(now[1]) * 1000 + math.floor(tonumber(now[2]) / 1000))
      if remaining <= 0 then return 0 end
      for index = 2, #KEYS do
        redis.call('SET', KEYS[index], ARGV[index + 1], 'PX', remaining)
      end
      return 1
    LUA

    class << self
      # Return an entry (or nil for a missing record) keyed by [organization_id, provider_id].
      def fetch_events(pairs)
        fetch_records(:events, EventbriteEvent, pairs, %i[name starts_at ends_at timezone])
      end

      def fetch_ticket_classes(pairs)
        fetch_records(:ticket_classes, EventbriteTicketClass, pairs, %i[name])
      end

      def signup_choices
        now = Time.current.in_time_zone('America/New_York')
        day = now.to_date
        following = day + 1.day
        midnight = now.time_zone.local(following.year, following.month, following.day)
        expires_at = [Time.current.to_f + TTL, midnight.to_f].min
        key = data_key(:signup, day.iso8601)
        token, values = read(:signup, [key])
        cached = decode(values.first, :signup, token) if token
        return cached[:entry] if cached

        rows = EventbriteEvent.signup_choices.only(:id, :name, :starts_at, :timezone).map do |event|
          { 'id' => event.id.to_s, 'name' => event.name, 'startsAt' => event.starts_at.iso8601, 'timezone' => event.timezone }
        end
        publish(:signup, token, { key => rows }, expires_at) if token
        rows
      end

      # A generation change also invalidates any in-flight fill and every org configuration.
      # Callback-bypassing callers must invalidate explicitly after successful persistence.
      def invalidate_events(_pairs = nil)
        invalidate(:events)
      end

      def invalidate_ticket_classes(_pairs = nil)
        invalidate(:ticket_classes)
      end

      def invalidate_signup_choices
        invalidate(:signup)
      end

      def invalidate_all
        %i[events ticket_classes signup].each { |kind| invalidate(kind) }
      end

      # Invoke outside an outer transaction. Partial imports must invalidate too.
      def with_event_changes(pairs = nil)
        yield
      ensure
        invalidate_events(pairs)
        invalidate_signup_choices
      end

      def with_ticket_class_changes(pairs = nil)
        yield
      ensure
        invalidate_ticket_classes(pairs)
      end

      def generation_key(kind)
        "#{base_namespace}:#{kind}:generation"
      end

      private

      def base_namespace
        "eventbrite_display:v#{VERSION}:#{Rails.env}:#{EventbriteEvent.collection.database.name}"
      end

      def data_key(kind, identity)
        organizations = Digest::SHA256.hexdigest(Configuration.organization_ids.sort.to_json)
        "#{base_namespace}:#{organizations}:#{kind}:#{Digest::SHA256.hexdigest(identity.to_json)}"
      end

      # Read generation and values atomically in one roundtrip. Fixed data keys
      # remain safe after invalidation because every payload carries its generation.
      def read(kind, keys)
        best_effort do
          result = REDIS.eval(READ, keys: [generation_key(kind), *keys], argv: [SecureRandom.uuid])
          [result.first, result.drop(1)]
        end || [nil, []]
      end

      def invalidate(kind)
        best_effort { REDIS.set(generation_key(kind), SecureRandom.uuid) }
      end

      def fetch_records(kind, model, pairs, fields)
        pairs = pairs.map { |org, id| [org.to_s, id.to_s] }.uniq
        return {} if pairs.empty?

        expires_at = Time.current.to_f + TTL
        keys = pairs.to_h { |pair| [pair, data_key(kind, pair)] }
        token, cached = read(kind, keys.values)
        result = {}
        pairs.each_with_index do |pair, index|
          decoded = decode(cached[index], kind, token) if token
          result[pair] = decoded[:entry] if decoded
        end
        missing = pairs.reject { |pair| result.key?(pair) }
        return result if missing.empty?

        rows = {}
        missing.each_slice(1000) do |batch|
          model.where('$or' => batch.map { |org, id| { organization_id: org, eventbrite_id: id } })
            .only(:organization_id, :eventbrite_id, *fields).each do |record|
            rows[[record.organization_id, record.eventbrite_id]] = fields.to_h { |field| [field.to_s, record.public_send(field)] }
          end
        end
        missing.each { |pair| result[pair] = rows[pair] }
        publish(kind, token, missing.to_h { |pair| [keys[pair], result[pair]] }, expires_at) if token
        result
      end

      def publish(kind, token, entries, expires_at)
        return if entries.empty?
        values = entries.values.map do |entry|
          if kind == :events && entry
            entry = entry.merge('starts_at' => entry['starts_at']&.iso8601(6), 'ends_at' => entry['ends_at']&.iso8601(6))
          end
          JSON.generate(version: VERSION, generation: token, expires_at: expires_at, entry: entry)
        end
        best_effort do
          REDIS.eval(PUBLISH, keys: [generation_key(kind), *entries.keys],
            argv: [token, (expires_at * 1000).floor, *values]).to_i == 1
        end
      end

      def decode(raw, kind, token)
        return nil unless raw
        payload = JSON.parse(raw)
        return nil unless payload.is_a?(Hash) && payload['version'] == VERSION && payload['generation'] == token &&
          payload['expires_at'].is_a?(Numeric) && payload['expires_at'] > Time.current.to_f

        entry = payload['entry']
        if kind == :signup
          return nil unless entry.is_a?(Array) && entry.all? { |row| valid_signup_row?(row) }
        elsif !entry.nil?
          fields = kind == :events ? %w[name starts_at ends_at timezone] : %w[name]
          return nil unless entry.is_a?(Hash) && entry.keys.sort == fields.sort && entry.values.all? { |value| value.nil? || value.is_a?(String) }
          if kind == :events
            %w[starts_at ends_at].each { |field| entry[field] = Time.iso8601(entry[field]) if entry[field] }
          end
        elsif !payload.key?('entry')
          return nil
        end
        { entry: entry }
      rescue JSON::ParserError, ArgumentError, TypeError
        nil
      end

      def valid_signup_row?(row)
        row.is_a?(Hash) && row.keys.sort == %w[id name startsAt timezone] &&
          row['id'].is_a?(String) && BSON::ObjectId.legal?(row['id']) &&
          row['startsAt'].is_a?(String) && Time.iso8601(row['startsAt']) &&
          %w[name timezone].all? { |field| row[field].nil? || row[field].is_a?(String) }
      end

      def best_effort
        yield
      rescue *CACHE_ERRORS => error
        Rails.logger.warn("[EventbriteDisplayCache] cache unavailable: #{error.class}")
        nil
      end
    end
  end
end
