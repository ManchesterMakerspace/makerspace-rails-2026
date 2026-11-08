# Limits how often a member can press "Pay now" on a past-due subscription, so the portal cannot be used to hammer a card
# (card issuers count repeated attempts, and too many can get the card blocked for good):
#   * a cooldown between attempts on the same subscription
#   * a daily cap of attempts per subscription
#
# One Lua script checks both and counts the attempt only if neither is exceeded, so two clicks at once cannot both get
# through (the counters are in Redis, like HouseholdInviteLimit). Only attempts that reach Braintree are meant to be
# claimed; release gives one back when the call failed before Braintree answered.
module PayNowLimit
  COOLDOWN_SECONDS = 60 * 60
  PER_DAY = 3
  DAY_SECONDS = 24 * 60 * 60

  # KEYS: cooldown, day count. ARGV: cooldown seconds, daily cap, day seconds.
  # Returns 0 when allowed (and counted), 1 cooldown, 2 daily cap. The daily cap is checked first because it lasts longer.
  SCRIPT = <<~LUA.freeze
    local count = tonumber(redis.call('get', KEYS[2]) or '0')
    if count >= tonumber(ARGV[2]) then return 2 end
    if redis.call('exists', KEYS[1]) == 1 then return 1 end
    redis.call('set', KEYS[1], '1', 'EX', tonumber(ARGV[1]))
    if redis.call('incr', KEYS[2]) == 1 then redis.call('expire', KEYS[2], tonumber(ARGV[3])) end
    return 0
  LUA

  class << self
    # Raises PayNow::Refused (HTTP 429, saying when to try again) unless this attempt is allowed, and counts it if so.
    def claim!(subscription_id)
      result = REDIS.eval(
        SCRIPT,
        keys: [cooldown_key(subscription_id), day_key(subscription_id)],
        argv: [COOLDOWN_SECONDS, PER_DAY, DAY_SECONDS]
      ).to_i
      return true if result.zero?

      state = status(subscription_id)
      state = { state: result == 2 ? :daily_cap : :cooldown, retry_at: nil } if state[:state] == :available
      raise PayNow::Refused.new(429, state[:state].to_s, refusal_message(state[:state]), state[:retry_at])
    end

    # Gives back an attempt that never reached Braintree's decision (the call raised before an answer came back).
    def release(subscription_id)
      REDIS.del(cooldown_key(subscription_id))
      day = day_key(subscription_id)
      REDIS.decr(day) if REDIS.get(day).to_i.positive?
    end

    # { state: :available | :cooldown | :daily_cap, retry_at: Time or nil }, read-only.
    def status(subscription_id)
      if REDIS.get(day_key(subscription_id)).to_i >= PER_DAY
        { state: :daily_cap, retry_at: expiry_of(day_key(subscription_id)) }
      elsif (retry_at = expiry_of(cooldown_key(subscription_id)))
        { state: :cooldown, retry_at: retry_at }
      else
        { state: :available, retry_at: nil }
      end
    end

    private

    def refusal_message(state)
      if state == :daily_cap
        "You have reached today's limit of #{PER_DAY} payment attempts. Try again tomorrow, or ask staff for help."
      else
        "A payment was just attempted. Wait an hour before trying again."
      end
    end

    def expiry_of(key)
      milliseconds = REDIS.pttl(key).to_i
      Time.current + (milliseconds / 1000.0) if milliseconds.positive?
    end

    def cooldown_key(subscription_id)
      "pay_now_cooldown/#{subscription_id}"
    end

    def day_key(subscription_id)
      "pay_now_day/#{subscription_id}"
    end
  end
end
