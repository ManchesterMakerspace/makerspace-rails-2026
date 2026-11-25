require 'rails_helper'

RSpec.describe SpecRedisCleanup do
  it 'clears rate limits and rotates cache generations while preserving unrelated keys', :aggregate_failures do
    suffix = SecureRandom.hex(8)
    rate_limits = %w[pay_now_cooldown/ pay_now_day/ pay_now_handled/ household_invite_cooldown/ household_invite_day/]
    limit_keys = rate_limits.flat_map { |prefix| Array.new(30) { |index| "#{prefix}#{suffix}/#{index}" } }
    unrelated_key = "spec_redis_cleanup:#{suffix}"
    shop_key = AvailableShopCache.data_key
    eventbrite_generations = %i[events ticket_classes signup].map do |kind|
      EventbriteIntegration::DisplayCache.generation_key(kind)
    end
    generations = [AvailableShopCache.generation_key, *eventbrite_generations]
    keys = [*limit_keys, unrelated_key, shop_key, *generations]
    REDIS.mset(*keys.flat_map { |key| [key, 'old'] })

    described_class.reset!

    expect(REDIS.mget(*limit_keys)).to all(be_nil)
    expect(REDIS.get(unrelated_key)).to eq('old')
    expect(REDIS.get(shop_key)).to be_nil
    current_generations = REDIS.mget(*generations)
    expect(current_generations).to all(be_present)
    expect(current_generations).not_to include('old')
  ensure
    REDIS.del(*limit_keys, unrelated_key) if unrelated_key
  end
end
