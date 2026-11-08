# The Pay now limits and the "already settled by Pay now" markers live in Redis, which is shared between examples, so
# clear them before each one. An example that presses the button twice in a row calls clear_pay_now_cooldown between the two.
module PayNowLimitHelpers
  def clear_pay_now_limits
    %w[pay_now_cooldown/* pay_now_day/* pay_now_handled/*].each do |pattern|
      REDIS.scan_each(match: pattern) { |key| REDIS.del(key) }
    end
  end

  def clear_pay_now_cooldown
    REDIS.scan_each(match: 'pay_now_cooldown/*') { |key| REDIS.del(key) }
  end
end

RSpec.configure do |config|
  config.include PayNowLimitHelpers
  config.before(:each) { clear_pay_now_limits }
end
