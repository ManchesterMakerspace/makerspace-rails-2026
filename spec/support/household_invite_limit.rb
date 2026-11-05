# The invitation send limits live in Redis, which is shared between examples, so clear them before each one. An example that
# deliberately sends to the same address twice in a row calls clear_household_invite_cooldown between the sends.
module HouseholdInviteLimitHelpers
  def clear_household_invite_limits
    REDIS.scan_each(match: 'household_invite_*') { |key| REDIS.del(key) }
  end

  def clear_household_invite_cooldown
    REDIS.scan_each(match: 'household_invite_cooldown/*') { |key| REDIS.del(key) }
  end
end

RSpec.configure do |config|
  config.include HouseholdInviteLimitHelpers
  config.before(:each) { clear_household_invite_limits }
end
