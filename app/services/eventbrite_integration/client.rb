require 'faraday'
require 'digest'
require 'time'
require 'cgi'
module EventbriteIntegration
  class Client
    class ApiError < StandardError
      DESCRIPTION_LIMIT = 512
      # Only fixed API vocabulary may survive quoted-value redaction.
      SAFE_VALUES = %w[status expand event_id changed_since continuation time_filter show_series_parent
        refund_request_statuses active inactive both all_not_deleted attendees refund_requests
        attendees,refund_requests all past current_future true false].freeze
      attr_reader :status, :code, :description
      def initialize(status, code, description: nil, sensitive_values: [])
        @status, @code = status, code.to_s
        @description = sanitize_description(description, sensitive_values)
        message = "Eventbrite API returned #{status} (#{@code.gsub(/[^A-Z_]/, '')})"
        message += ": #{@description}" if @description.present?
        super(message)
      end

      private
      def sanitize_description(value, sensitive_values)
        return unless value.is_a?(String) && value.present?
        return '[OMITTED: oversized error description]' if value.bytesize > 16_384
        text = value.encode('UTF-8', invalid: :replace, undef: :replace).gsub(/[\p{Cf}]/, '')
        text.gsub!(/\bBearer\s+[^\s"'<>]+/i, 'Bearer [REDACTED]')
        text.gsub!(%r{https?://[^\s<>"']+}i, '[REDACTED_URL]')
        text.gsub!(/[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}/i, '[REDACTED_EMAIL]')
        inputs = sensitive_values.reject { |v| SAFE_VALUES.include?(v) }
        secrets = [Configuration.token, Configuration.webhook_path, *inputs].select { |v| v.is_a?(String) && v.present? }
        secrets.flat_map { |v| [v, CGI.escape(v), CGI.escapeHTML(v)] }.uniq.sort_by { |v| -v.length }.each do |secret|
          text.gsub!(/#{Regexp.escape(secret)}/i, '[REDACTED]')
        end
        return '[REDACTED: sensitive validation details]' if text.match?(/\b(?:email|e-mail|name|address|phone|profile|buyer|payer|password|token|secret|cookie|authorization)\b/i)
        # Provider validation errors can echo arbitrary input, including names.
        text.gsub!(/(["'`])([^"'`]*)\1/) { SAFE_VALUES.include?($2) ? $& : '[REDACTED]' }
        text.gsub!(/[A-Za-z0-9_\-]{24,}/, '[REDACTED]')
        text.gsub!(/[[:cntrl:]\p{Zl}\p{Zp}]/, ' ')
        text = text.split.join(' ')
        return if text.empty?
        text.length > DESCRIPTION_LIMIT ? "#{text[0, DESCRIPTION_LIMIT - 3]}..." : text
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
      raise ArgumentError, 'Invalid API path' unless path.match?(%r{\Aseries/[A-Za-z0-9_-]+/events/\z}) || path == 'users/me/organizations/' ||
        (path.match?(%r{\A(?:events|orders|attendees|organizations)/[A-Za-z0-9_/-]+/\z}) && !path.include?('//'))
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
          unless response.status.between?(200, 299)
            raise ApiError.new(response.status, body['error'], description: body['error_description'],
              sensitive_values: params.values.flatten)
          end
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
