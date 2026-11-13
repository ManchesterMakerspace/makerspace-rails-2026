require 'faraday'
require 'digest'
require 'time'
module EventbriteIntegration
  class Client
    class ApiError < StandardError
      attr_reader :status, :code
      def initialize(status, code)
        @status, @code = status, code.to_s
        super("Eventbrite API returned #{status} (#{@code.gsub(/[^A-Z_]/, '')})")
      end
    end
    class Deferred < StandardError
      attr_reader :delay
      def initialize(delay) = (@delay = [delay.to_f, 0.5].max; super('Eventbrite API work deferred'))
    end
    # Called under the token lease: a rolling budget shared by every worker/task.
    def initialize
      Configuration.validate!
      @key = "eventbrite:api:#{Digest::SHA256.hexdigest(Configuration.token)}"
      @http = Faraday.new(url: 'https://www.eventbriteapi.com/v3/') do |f|
        f.options.open_timeout = 5
        f.options.timeout = 30
      end
    end
    def get(path, params = {})
      raise ArgumentError, 'Invalid API path' unless path.match?(%r{\A(?:events|orders|attendees|organizations)/[A-Za-z0-9_/-]+/\z}) && !path.include?('//')
      Lease.with(@key) do |check|
        now = Time.now.to_f
        wait = REDIS.get("#{@key}:next").to_f - now
        wait = [wait, REDIS.get("#{@key}:cooldown").to_f - now].max
        raise Deferred.new(wait) if wait > 0.6
        sleep(wait) if wait > 0
        now = Time.now.to_f
        REDIS.zremrangebyscore(@key, '-inf', now - 86_400)
        [[3600, 2000], [86_400, 48_000]].each do |seconds, limit|
          if REDIS.zcount(@key, now - seconds, '+inf') >= limit
            first = REDIS.zrangebyscore(@key, now - seconds, '+inf', with_scores: true, limit: [0, 1]).first
            raise Deferred.new(first[1].to_f + seconds - now + 0.5)
          end
        end
        REDIS.zadd(@key, now, SecureRandom.uuid)
        REDIS.expire(@key, 86_401)
        begin
          response = @http.get(path, params) { |r| r.headers['Authorization'] = "Bearer #{Configuration.token}" }
          check.call
          body = JSON.parse(response.body) rescue {}
          body = {} unless body.is_a?(Hash)
          if response.status == 429
            attempts = REDIS.incr("#{@key}:429")
            REDIS.expire("#{@key}:429", 3600)
            header = response.headers['retry-after']
            delay = if header.to_s.match?(/\A\d+\z/)
              header.to_i
            elsif header.present?
              (Time.httpdate(header) - Time.now rescue 60)
            else
              [60 * (2 ** [attempts - 1, 6].min), 3600].min + rand(10)
            end
            REDIS.set("#{@key}:cooldown", Time.now.to_f + [delay, 0.5].max, ex: [delay.ceil + 1, 1].max)
            raise Deferred.new(delay)
          end
          raise ApiError.new(response.status, body['error']) unless response.status.between?(200, 299)
          raise ApiError.new(502, 'INVALID_RESPONSE') unless body.is_a?(Hash) && body.present?
          REDIS.del("#{@key}:429")
          body
        ensure
          REDIS.set("#{@key}:next", Time.now.to_f + 0.5, ex: 120)
        end
      end
    end

    def each_page(path, params = {}, continuation: nil)
      seen = []
      loop do
        body = get(path, continuation ? params.merge('continuation' => continuation) : params)
        pagination = body.fetch('pagination')
        next_token = pagination['has_more_items'] ? pagination['continuation'].presence : nil
        if pagination['has_more_items'] && (!next_token || seen.include?(next_token) || next_token == continuation)
          raise ApiError.new(502, 'INVALID_PAGINATION')
        end
        yield body, next_token
        break unless next_token
        seen << next_token
        continuation = next_token
      end
    end
  end
end
