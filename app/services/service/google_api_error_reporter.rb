module Service
  module GoogleApiErrorReporter
    class << self
      def report_if_permission_denied(error, operation:, resource_type: "GoogleApi", resource_id: nil)
        return false unless permission_denied?(error)
        return true if error.instance_variable_get(:@permission_denied_reported)

        error.instance_variable_set(:@permission_denied_reported, true)
        full_message = full_error_message(error)
        resolved_resource_id = valid_object_id(resource_id) || Current.actor&.id || BSON::ObjectId.new

        Service::AuditLogger.log(
          log_type: "portal",
          event_type: "google_api_permission_denied",
          resource_type: resource_type.to_s,
          resource_id: resolved_resource_id,
          actor: Current.actor,
          after_snapshot: {
            operation: operation,
            error_class: error.class.name,
            error_message: full_message
          }
        )

        Rails.logger.error(
          "[GoogleApiPermissionDenied] operation=#{operation} resource=#{resource_type}/#{resolved_resource_id}\n" \
          "#{full_message}"
        )
        slack_alert(operation: operation, resource_type: resource_type,
          resource_id: resolved_resource_id, full_message: full_message)
        Honeybadger.notify(error) if defined?(Honeybadger)
        true
      rescue => reporting_error
        Rails.logger.error(
          "[GoogleApiPermissionDenied] reporting failed: #{reporting_error.class}: #{reporting_error.message}"
        )
        false
      end

      def permission_denied?(error)
        status_code = error.respond_to?(:status_code) ? error.status_code.to_i : 0
        text = full_error_message(error)
        status_code == 403 ||
          text.match?(/PERMISSION_DENIED|permission denied|insufficient permissions/i)
      end

      def full_error_message(error)
        [
          "#{error.class}: #{error.message}",
          (error.body if error.respond_to?(:body)),
          (error.response_header if error.respond_to?(:response_header))
        ].compact.map(&:to_s).reject(&:blank?).uniq.join("\n")
      end

      def slack_alert(operation:, resource_type:, resource_id:, full_message:)
        Service::SlackConnector.send_slack_message(
          "<!channel> *Google API PERMISSION_DENIED*\n" \
          "- operation: #{operation}\n" \
          "- resource: #{resource_type}/#{resource_id}\n" \
          "```#{full_message}```",
          Service::SlackConnector.logs_channel
        )
      end

      private

      def valid_object_id(value)
        return value if value.is_a?(BSON::ObjectId)
        return nil unless BSON::ObjectId.legal?(value.to_s)
        BSON::ObjectId.from_string(value.to_s)
      end
    end
  end
end
