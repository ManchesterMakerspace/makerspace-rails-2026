# Limits how many household invitation emails can be sent, so an eligible household account cannot be used to flood someone's
# inbox, burn mail capacity, or keep invalidating a link that was already emailed (every send replaces the link).
#
# Applied to both ways of sending (a new invite to an address that already has an open invitation, and Resend) before the
# link is replaced:
#   * a cooldown for the same sender and recipient pair
#   * a daily cap per sender (all recipients)
#   * a daily cap per recipient (all senders)
#
# One Lua script checks all three and counts the send only if none is exceeded, so concurrent requests cannot slip past
# (the counters are in Redis, like the other short-lived locks). Emails are hashed in the key names.
module HouseholdInviteLimit
  COOLDOWN_SECONDS = 60
  PER_SENDER_PER_DAY = 10
  PER_RECIPIENT_PER_DAY = 5
  DAY_SECONDS = 24 * 60 * 60

  # KEYS: cooldown, sender day count, recipient day count. ARGV: cooldown seconds, sender cap, recipient cap, day seconds.
  # Returns 0 when allowed (and counted), 1 cooldown, 2 sender cap, 3 recipient cap.
  SCRIPT = <<~LUA.freeze
    if redis.call('exists', KEYS[1]) == 1 then return 1 end
    local sender = tonumber(redis.call('get', KEYS[2]) or '0')
    if sender >= tonumber(ARGV[2]) then return 2 end
    local recipient = tonumber(redis.call('get', KEYS[3]) or '0')
    if recipient >= tonumber(ARGV[3]) then return 3 end
    redis.call('set', KEYS[1], '1', 'EX', tonumber(ARGV[1]))
    if redis.call('incr', KEYS[2]) == 1 then redis.call('expire', KEYS[2], tonumber(ARGV[4])) end
    if redis.call('incr', KEYS[3]) == 1 then redis.call('expire', KEYS[3], tonumber(ARGV[4])) end
    return 0
  LUA

  class << self
    # Raises Error::TooManyRequests, saying what to wait for, unless this send is allowed.
    def claim!(sender_id:, recipient_email:)
      recipient = Digest::SHA256.hexdigest(recipient_email.to_s.strip.downcase)
      result = REDIS.eval(
        SCRIPT,
        keys: ["household_invite_cooldown/#{sender_id}/#{recipient}", "household_invite_sender/#{sender_id}", "household_invite_recipient/#{recipient}"],
        argv: [COOLDOWN_SECONDS, PER_SENDER_PER_DAY, PER_RECIPIENT_PER_DAY, DAY_SECONDS]
      ).to_i

      case result
      when 0 then true
      when 1 then raise ::Error::TooManyRequests.new("An invitation was just sent to that address. Wait a minute before sending it again.")
      when 2 then raise ::Error::TooManyRequests.new("You have reached today's limit of #{PER_SENDER_PER_DAY} invitation emails. Try again tomorrow, or ask staff for help.")
      else raise ::Error::TooManyRequests.new("Too many invitations were sent to that address today. Try again tomorrow.")
      end
    end
  end
end
