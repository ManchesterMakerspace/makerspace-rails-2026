require 'digest'
module EventbriteIntegration
  class Lease
    RELEASE = "if redis.call('GET',KEYS[1]) == ARGV[1] then return redis.call('DEL',KEYS[1]) else return 0 end".freeze
    RENEW = "if redis.call('GET',KEYS[1]) == ARGV[1] then return redis.call('EXPIRE',KEYS[1],120) else return 0 end".freeze
    def self.with(key, renew: nil)
      key = "eventbrite:lease:#{Digest::SHA256.hexdigest(key)}"
      token = SecureRandom.uuid
      raise Client::Deferred.new(1) unless REDIS.set(key, token, nx: true, ex: 120)
      owned = true
      mutex = Mutex.new
      condition = ConditionVariable.new
      stopped = false
      heartbeat = Thread.new do
        loop do
          break if mutex.synchronize { condition.wait(mutex, 30) unless stopped; stopped }
          owned = REDIS.eval(RENEW, keys: [key], argv: [token]).to_i == 1
          owned &&= renew.call if renew
          break unless owned
        rescue StandardError
          owned = false
          break
        end
      end
      check = -> { raise Client::Deferred.new(5) unless owned && REDIS.get(key) == token }
      yield check
    ensure
      if heartbeat
        mutex.synchronize { stopped = true; condition.signal }
        heartbeat.join
        REDIS.eval(RELEASE, keys: [key], argv: [token])
      end
    end
  end
end
