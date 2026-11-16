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
    class InvalidPathError < ArgumentError
      ROOTS = %w[series events orders attendees organizations users].freeze
      CHILDREN = {
        'events' => %w[orders attendees ticket_classes inventory_tiers],
        'series' => %w[events], 'organizations' => %w[events orders attendees],
        'users' => %w[organizations]
      }.freeze

      def initialize(path)
        super("Invalid API path: #{diagnostic(path)}")
      end

      private
      def diagnostic(path)
        return 'type=nil; raw value omitted' if path.nil?
        return 'type=non-string; raw value omitted' unless path.is_a?(String)
        return "bytes=#{path.bytesize}; oversized=true; raw value omitted" if path.bytesize > 4096

        # Only fixed vocabulary and structural metadata may leave this method.
        # Do not interpolate provider IDs, URL authorities, query values or raw input.
        raw = path.b
        flags = []
        flags << 'empty' if raw.empty?
        flags << 'absolute_url' if raw.match?(%r{\A[a-z][a-z0-9+.-]*://}in)
        flags << 'leading_slash' if raw.start_with?('/')
        flags << 'version_prefix' if raw.match?(%r{\A/*v[0-9]+/}n)
        flags << 'query' if raw.include?('?')
        flags << 'fragment' if raw.include?('#')
        flags << 'whitespace' if raw.match?(/[\t\n\r\f\v ]/n)
        flags << 'control' if raw.match?(/[\x00-\x1f\x7f]/n)
        flags << 'non_ascii' unless raw.ascii_only?
        flags << 'invalid_utf8' unless raw.dup.force_encoding(Encoding::UTF_8).valid_encoding?
        flags << 'percent_encoding' if raw.include?('%')
        flags << 'backslash' if raw.include?('\\')
        flags << 'other_characters' if raw.match?(%r{[^A-Za-z0-9_/\-]}n)
        route = raw.split(/[?#]/n, 2).first.to_s.sub(%r{\A[a-z][a-z0-9+.-]*://[^/]*}in, '')
        flags << 'missing_trailing_slash' unless route.end_with?('/')
        flags << 'repeated_slash' if route.include?('//')
        root = route.split('/').find { |part| !part.empty? }
        flags << 'unsupported_namespace' unless ROOTS.include?(root)
        secrets = [Configuration.token, Configuration.webhook_path].select(&:present?)
        sensitive = secrets.any? do |value|
          [value, CGI.escape(value), CGI.escapeHTML(value)].any? { |secret| raw.downcase.include?(secret.b.downcase) }
        end
        flags << 'sensitive_value' if sensitive
        shape = if sensitive
          '[REDACTED]'
        else
          parts = route.split('/', -1)
          prefix = parts.take_while(&:empty?).length
          root_index = prefix + (parts[prefix] == 'v3' ? 1 : 0)
          root = parts[root_index]
          literals = []
          literals << prefix if root_index > prefix
          literals << root_index if ROOTS.include?(root)
          literals << root_index + 1 if root == 'users' && parts[root_index + 1] == 'me'
          literals << root_index + 2 if Array(CHILDREN[root]).include?(parts[root_index + 2])
          result = parts.first(8).each_with_index.map do |part, index|
            if part.empty? || literals.include?(index)
              part
            else
              kind = part.match?(/\A[A-Za-z0-9_-]+\z/n) ? 'id' : 'invalid'
              "<#{kind} bytes=#{part.bytesize}>"
            end
          end.join('/')
          result += '/[remaining segments omitted]' if parts.length > 8
          result
        end
        "shape=#{shape}; bytes=#{raw.bytesize}; flags=#{flags.empty? ? 'invalid_format' : flags.join(',')}"[0, 512]
      end
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
      valid = path.is_a?(String) && path.ascii_only? && (
        path.match?(%r{\Aseries/[A-Za-z0-9_-]+/events/\z}) || path == 'users/me/organizations/' ||
        (path.match?(%r{\A(?:events|orders|attendees|organizations)/[A-Za-z0-9_/-]+/\z}) && !path.include?('//')))
      raise InvalidPathError.new(path) unless valid
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
