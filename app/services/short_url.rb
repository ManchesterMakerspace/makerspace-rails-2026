class ShortUrl
  class InvalidTarget < StandardError; end
  class Unavailable < StandardError; end
  ALPHABET = "23456789ABCDEFGHIJKLMNOPQRSTUVWXYZ".freeze
  SPACE = 34**10
  TTL = 86_400
  KEY_PREFIX = "shortcodes:v1:"
  CODE = /\A[2-9A-Z]{10}\z/
  PUBLIC_PATH = %r{\A/(?:api/)?(shop|tool)/([a-f0-9]{24})/public\.html\z}
  PLURAL_PATH = %r{\A/(shops|tools)/([a-f0-9]{24})/public\.html\z}
  CHECKOUT_PATH = %r{\A/tools/([a-f0-9]{24})/request-checkout\z}
  RENTAL_PATH = %r{\A/rentals/spots/([a-f0-9]{24})\z}

  def self.base_url
    AppDomainUrl.base_url(ENV.fetch("APP_DOMAIN"), environment: Rails.env)
  end

  def self.normalize(value)
    value = value.to_s
    uri = URI.parse(value)
    base = URI.parse(base_url)
    if value.start_with?("/") && !value.start_with?("//")
      uri = URI.join(base.to_s, value)
    end
    raise InvalidTarget unless uri.is_a?(URI::HTTP) &&
      uri.scheme == base.scheme && uri.host&.downcase == base.host&.downcase && uri.port == base.port &&
      !uri.userinfo && !uri.query && !uri.fragment && supported_path?(uri.path)
    "#{base.to_s.sub(%r{/+\z}, '')}#{uri.path}"
  rescue URI::Error, KeyError
    raise InvalidTarget
  end

  def self.supported_path?(path)
    PUBLIC_PATH.match?(path) || PLURAL_PATH.match?(path) || CHECKOUT_PATH.match?(path) || RENTAL_PATH.match?(path)
  end

  def self.visible!(url)
    path = URI.parse(url).path
    if (match = PUBLIC_PATH.match(path)) || (match = PLURAL_PATH.match(path))
      match[1].start_with?("shop") ? PublicCatalog.shop(match[2]) : PublicCatalog.tool(match[2])
    elsif (match = CHECKOUT_PATH.match(path))
      PublicCatalog.tool(match[1])
    elsif (match = RENTAL_PATH.match(path))
      raise PublicCatalog::Unavailable unless RentalSpot.where(id: match[1], active: true).exists?
    else
      raise InvalidTarget
    end
  rescue Mongo::Error => error
    Rails.logger.error("[ShortUrl] visibility lookup failed: #{error.class}")
    raise Unavailable
  end

  def self.encode(number)
    value = number % SPACE
    result = ""
    10.times { result.prepend(ALPHABET[value % 34]); value /= 34 }
    result
  end

  def self.allocate(value)
    target = normalize(value)
    verify_indexes!
    existing = Shortcode.where(target_url: target).first
    return publish(existing) if existing
    number = Digest::SHA256.hexdigest(target).to_i(16) % SPACE
    SPACE.times do
      code = encode(number)
      # Cache is advisory during allocation; Mongo uniquely owns every code.
      cache_target = cached(code)
      existing = Shortcode.where(code: code).first
      if cache_target && cache_target != existing&.target_url
        Rails.logger.warn("[ShortUrl] stale cache during allocation code=#{code}")
      end
      return publish(existing) if existing&.target_url == target
      unless existing
        begin
          return publish(Shortcode.create!(code: code, target_url: target))
        rescue Mongo::Error::OperationFailure => error
          raise unless error.code == 11000
          existing = Shortcode.where(target_url: target).first
          return publish(existing) if existing
        end
      end
      Rails.logger.info("[ShortUrl] allocation collision code=#{code}")
      number = (number + 1) % SPACE
    end
    raise Unavailable
  rescue Mongo::Error => error
    Rails.logger.error("[ShortUrl] allocation failed: #{error.class}")
    raise Unavailable
  end

  def self.verify_indexes!
    return if @indexes_verified
    indexes = Shortcode.collection.indexes.to_a
    valid = %w[code target_url].all? do |field|
      indexes.any? { |index| index["key"] == { field => 1 } && index["unique"] == true && !index["sparse"] && !index["partialFilterExpression"] }
    end
    unless valid
      Rails.logger.error("[ShortUrl] unique indexes missing; run rake shortcodes:ensure_indexes")
      raise Unavailable
    end
    @indexes_verified = true
  end

  def self.publish(record)
    cache(record.code, record.target_url)
    { code: record.code, short_url: "#{base_url}/L#{record.code}".upcase }
  end

  def self.resolve(code)
    return nil unless CODE.match?(code.to_s)
    value = cached(code)
    return value if value
    record = Shortcode.where(code: code).only(:target_url).first
    return nil unless record
    value = normalize(record.target_url)
    cache(code, value)
    value
  rescue InvalidTarget
    nil
  rescue Mongo::Error => error
    Rails.logger.error("[ShortUrl] resolution failed: #{error.class}")
    raise Unavailable
  end

  def self.cached(code)
    value = REDIS.get("#{KEY_PREFIX}#{code}")
    value.present? ? normalize(value) : nil
  rescue InvalidTarget
    nil
  rescue Redis::BaseError, IOError => error
    Rails.logger.warn("[ShortUrl] cache read failed: #{error.class}")
    nil
  end

  def self.cache(code, target)
    REDIS.set("#{KEY_PREFIX}#{code}", target, ex: TTL)
  rescue Redis::BaseError, IOError => error
    Rails.logger.warn("[ShortUrl] cache write failed: #{error.class}")
  end
end
