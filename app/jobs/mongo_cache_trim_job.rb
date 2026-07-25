class MongoCacheTrimJob < ApplicationJob
  queue_as :critical

  def perform
    cursor = "0"
    pattern = "makerspace:cache:v1:*mongo*"

    loop do
      cursor, keys = REDIS.scan(cursor, match: pattern, count: 100)
      keys.reject! { |key| key.include?("/generations/") }
      keys.each_slice(25) do |batch|
        REDIS.unlink(*batch) if batch.present?
        return if used_memory < MongoCache::LOW_WATER_BYTES
      end
      break if cursor == "0"
    end
  ensure
    REDIS.del("locks:mongo_cache_trim")
  end

  private

  def used_memory
    REDIS.info("memory").fetch("used_memory").to_i
  end
end
