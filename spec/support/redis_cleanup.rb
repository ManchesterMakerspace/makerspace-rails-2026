module SpecRedisCleanup
  LIMIT_PATTERNS = %w[pay_now_cooldown/* pay_now_day/* pay_now_handled/* household_invite_*].freeze

  def self.reset!
    cursors = LIMIT_PATTERNS.to_h { |pattern| [pattern, '0'] }
    reset_caches = true

    until cursors.empty?
      scans = {}
      REDIS.pipelined do |pipeline|
        enqueue_cache_reset(pipeline) if reset_caches
        cursors.each { |pattern, cursor| scans[pattern] = pipeline.scan(cursor, match: pattern) }
      end
      reset_caches = false

      keys = []
      cursors = scans.filter_map do |pattern, reply|
        cursor, found = reply.value
        keys.concat(found)
        [pattern, cursor] unless cursor == '0'
      end.to_h
      keys.each_slice(500) { |batch| REDIS.del(*batch) }
    end
  end

  def self.enqueue_cache_reset(pipeline)
    # DatabaseCleaner bypasses model callbacks. Rotate the same generation keys
    # as the app, so a fill started before cleanup cannot publish stale data.
    pipeline.eval(AvailableShopCache::INVALIDATE,
      keys: [AvailableShopCache.generation_key, AvailableShopCache.data_key], argv: [SecureRandom.uuid])
    %i[events ticket_classes signup].each do |kind|
      pipeline.set(EventbriteIntegration::DisplayCache.generation_key(kind), SecureRandom.uuid)
    end
  end
  private_class_method :enqueue_cache_reset

  # Individual examples can lift a cooldown between two calls to the same endpoint.
  def clear_pay_now_cooldown
    REDIS.scan_each(match: 'pay_now_cooldown/*') { |key| REDIS.del(key) }
  end

  def clear_household_invite_cooldown
    REDIS.scan_each(match: 'household_invite_cooldown/*') { |key| REDIS.del(key) }
  end
end
