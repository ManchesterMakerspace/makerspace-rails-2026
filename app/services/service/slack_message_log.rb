module Service
  # Records every Slack message the portal sends as an AuditLog entry
  # (log_type "slack"), so admins and the board can see what was posted where,
  # and to which member a DM went, next to the system_email_sent trail.
  #
  # Called from Service::SlackConnector.send_slack_message (which nearly every
  # message goes through, including the queued ones SlackMessagesJob sends) and
  # from the two jobs that still post directly: FixTicketDelivery and
  # ShopOutageSlackJob. Interactive replies to slash commands (ephemeral and
  # response_url answers) and edits of existing messages are not recorded.
  #
  # Recording never raises: a failed write is reported to Honeybadger and the
  # message itself is unaffected.
  module SlackMessageLog
    LOG_TYPE      = 'slack'.freeze
    SENT          = 'slack_message_sent'.freeze
    FAILED        = 'slack_message_failed'.freeze
    RESOURCE_TYPE = 'SlackChannel'.freeze
    MAX_TEXT      = 4000
    SLACK_USER_ID = /\A[UW][A-Z0-9]{6,}\z/

    # Off in the test environment so ordinary specs do not gain audit rows;
    # the specs for this module turn it on.
    mattr_accessor :enabled, default: !Rails.env.test?

    # channel:  the destination the caller asked for (channel name/ID, or a
    #           Slack user ID for a DM), before any non-production redirect.
    # message:  the text, or Block Kit blocks.
    # source:   which code sent it; worked out from the call stack when omitted.
    # response: Slack's chat.postMessage response, when the post succeeded.
    # error:    the exception, when it failed.
    def self.record(channel:, message:, source: nil, response: nil, error: nil)
      return unless enabled
      return if suppressed?
      return if channel.blank?

      member = dm_member(channel)
      AuditLog.create!(
        log_type:      LOG_TYPE,
        event_type:    error ? FAILED : SENT,
        resource_type: RESOURCE_TYPE,
        resource_id:   channel.to_s,
        subject_id:    member&.id,
        subject_name:  member&.fullname,
        slack_channel: channel.to_s,
        slack_message: text_of(message).presence || '(no text)',
        slack_posted:  error.nil?,
        after_snapshot: {
          'source'            => (source.presence || caller_source),
          'delivered_channel' => response && response['channel'],
          'ts'                => response && response['ts'],
          'error'             => error && "#{error.class}: #{error.message}"
        }.compact,
        ip_address:    Current.ip_address
      )
    rescue => e
      Rails.logger.error("[SlackMessageLog] Failed to record Slack message to #{channel}: #{e.class} #{e.message}") if Rails.respond_to?(:logger)
      Honeybadger.notify(e, context: { slack_channel: channel.to_s }) if defined?(Honeybadger)
      nil
    end

    # Runs the block without recording any Slack message sent inside it
    # (AuditLogger uses this for its own posts, which its entry already records).
    def self.without_logging
      previous = Thread.current[:slack_message_log_suppressed]
      Thread.current[:slack_message_log_suppressed] = true
      yield
    ensure
      Thread.current[:slack_message_log_suppressed] = previous
    end

    def self.suppressed?
      Thread.current[:slack_message_log_suppressed] == true
    end

    def self.dm_member(channel)
      return unless channel.to_s.match?(SLACK_USER_ID)
      SlackUser.where(slack_id: channel.to_s).first&.member
    end

    def self.text_of(message)
      text = case message
             when String then message
             when Array, Hash then block_text(message)
             else message.to_s
             end
      text.length > MAX_TEXT ? "#{text[0, MAX_TEXT]}…" : text
    end

    # Pulls the visible text out of Block Kit blocks, one line per text field.
    def self.block_text(node)
      case node
      when Array then node.map { |child| block_text(child) }.reject(&:blank?).join("\n")
      when Hash
        own = node['text'] || node[:text]
        own.is_a?(String) ? own : node.values.map { |child| block_text(child) }.reject(&:blank?).join("\n")
      else ''
      end
    end

    IGNORED_FRAMES = %w[slack_connector.rb slack_message_log.rb].freeze

    # "RentalLapseNotifier.notify_staff" style label of the first caller
    # outside the Slack plumbing.
    def self.caller_source
      frame = caller_locations(2, 30).find { |location| IGNORED_FRAMES.none? { |name| location.path.to_s.end_with?(name) } }
      return 'unknown' unless frame
      label = frame.label.to_s
      label.match?(/[#.]/) ? label : "#{File.basename(frame.path.to_s, '.rb')}:#{label}"
    end
  end
end
