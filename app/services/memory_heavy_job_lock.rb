class MemoryHeavyJobLock
  KEY = "locks:memory_heavy_job"

  def self.with_lock(expires_in: 30.minutes)
    token = SecureRandom.uuid
    acquired = REDIS.set(KEY, token, nx: true, ex: expires_in.to_i)
    raise "Another memory-heavy job is already running" unless acquired

    yield
  ensure
    release(token) if acquired
  end

  def self.release(token)
    REDIS.eval(
      "if redis.call('get', KEYS[1]) == ARGV[1] then return redis.call('del', KEYS[1]) else return 0 end",
      keys: [KEY],
      argv: [token]
    )
  rescue Redis::BaseError => error
    Honeybadger.notify(error) if defined?(Honeybadger)
  end
end
