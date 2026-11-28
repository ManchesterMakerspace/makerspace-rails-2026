# A renewable lease keeps a slow Slack request from overlapping another sender.
# Ownership is checked before external writes; only the owner releases the lock.
class SlackDeliveryLease
  class Busy < StandardError; end

  RELEASE = "if redis.call('GET',KEYS[1]) == ARGV[1] then return redis.call('DEL',KEYS[1]) else return 0 end".freeze
  RENEW = "if redis.call('GET',KEYS[1]) == ARGV[1] then return redis.call('EXPIRE',KEYS[1],120) else return 0 end".freeze

  def self.with(key)
    token = SecureRandom.uuid
    raise Busy, 'Slack delivery is already in progress' unless REDIS.set(key, token, nx: true, ex: 120)

    owned = true
    mutex = Mutex.new
    condition = ConditionVariable.new
    stopped = false
    heartbeat = Thread.new do
      loop do
        break if mutex.synchronize { condition.wait(mutex, 30) unless stopped; stopped }
        owned = REDIS.eval(RENEW, keys: [key], argv: [token]).to_i == 1
        break unless owned
      rescue StandardError
        owned = false
        break
      end
    end
    check = -> { raise Busy, 'Slack delivery lease expired' unless owned && REDIS.get(key) == token }
    yield check
  ensure
    if heartbeat
      mutex.synchronize { stopped = true; condition.signal }
      heartbeat.join
      begin
        REDIS.eval(RELEASE, keys: [key], argv: [token])
      rescue Redis::BaseError => error
        Rails.logger.warn("[SlackDeliveryLease] Release failed: #{error.class}")
      end
    end
  end
end
