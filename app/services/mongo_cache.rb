class MongoCache
  DEFAULT_TTL = 8.hours
  MIN_TTL_HOURS = 1
  MAX_TTL_HOURS = 24
  HIGH_WATER_BYTES = 18.megabytes
  LOW_WATER_BYTES = 16.megabytes
  MEMORY_CHECK_INTERVAL = 1.minute
  GENERATION_TTL = 30.days
  RACE_CONDITION_TTL = 10.seconds
  TTL_SETTING_CACHE_KEY = "settings/mongo_cache_ttl_hours"

  class << self
    def fetch(key, dependencies:, expires_in: ttl)
      return yield unless enabled?
      return yield if memory_pressure?

      dependency_versions = Array(dependencies).map do |dependency|
        "#{dependency}=#{generation(dependency)}"
      end
      cache_key = ["mongo", *dependency_versions, key]

      ActiveSupport::Notifications.instrument(
        "mongo_cache.fetch",
        key: key,
        dependencies: Array(dependencies)
      ) do
        Rails.cache.fetch(
          cache_key,
          expires_in: expires_in,
          race_condition_ttl: RACE_CONDITION_TTL
        ) do
          value = yield
          if value.is_a?(Mongoid::Criteria)
            raise ArgumentError, "MongoCache blocks must materialize Mongoid::Criteria with .to_a or .as_json"
          end
          value
        end
      end
    rescue Redis::BaseError => error
      report(error, operation: "fetch", key: key)
      yield
    end

    def invalidate(*dependencies)
      Array(dependencies).flatten.compact.each do |dependency|
        Rails.cache.write(
          generation_key(dependency),
          SecureRandom.hex(8),
          expires_in: GENERATION_TTL
        )
      end
    rescue => error
      report(error, operation: "invalidate", dependencies: dependencies)
      nil
    end

    def clear!
      Rails.cache.delete_matched("mongo/*")
    rescue => error
      report(error, operation: "clear")
      nil
    end

    def ttl
      value = Rails.cache.fetch(TTL_SETTING_CACHE_KEY, expires_in: 5.minutes) do
        SystemConfig.raw_get(SystemConfig::MONGO_CACHE_TTL_HOURS)
      end
      hours = Integer(value.presence || DEFAULT_TTL.in_hours)
      hours = DEFAULT_TTL.in_hours.to_i unless hours.between?(MIN_TTL_HOURS, MAX_TTL_HOURS)
      hours.hours
    rescue ArgumentError, TypeError
      DEFAULT_TTL
    rescue => error
      report(error, operation: "ttl")
      DEFAULT_TTL
    end

    def update_ttl!(value)
      Rails.cache.write(TTL_SETTING_CACHE_KEY, value.to_s, expires_in: 5.minutes)
    rescue => error
      report(error, operation: "update_ttl")
    end

    def enabled?
      return true unless Rails.env.production?

      ENV["MONGO_CACHE_ENABLED"] == "true"
    end

    private

    def generation(dependency)
      Rails.cache.fetch(
        generation_key(dependency),
        expires_in: GENERATION_TTL
      ) { SecureRandom.hex(8) }
    end

    def generation_key(dependency)
      "mongo/generations/#{dependency}"
    end

    def memory_pressure?
      return false unless Rails.env.production?

      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      memory_check_mutex.synchronize do
        if @last_memory_check_at.nil? || now - @last_memory_check_at >= MEMORY_CHECK_INTERVAL
          @last_memory_pressure = redis_used_memory >= HIGH_WATER_BYTES
          schedule_trim if @last_memory_pressure
          @last_memory_check_at = now
        end
        @last_memory_pressure
      end
    rescue => error
      report(error, operation: "memory_check")
      false
    end

    def redis_used_memory
      info = REDIS.info("memory")
      (info["used_memory"] || info[:used_memory]).to_i
    end

    def schedule_trim
      return unless REDIS.set("locks:mongo_cache_trim", "1", nx: true, ex: 5.minutes.to_i)

      MongoCacheTrimJob.perform_later
    rescue => error
      report(error, operation: "schedule_trim")
    end

    def memory_check_mutex
      @memory_check_mutex ||= Mutex.new
    end

    def report(error, context = {})
      Rails.logger.warn("[MongoCache] #{error.class}: #{error.message} context=#{context.inspect}")
      Honeybadger.notify(error, context: context) if defined?(Honeybadger)
    end
  end
end
