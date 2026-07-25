class AuditLogSlackJob < ApplicationJob
  queue_as :slack
  retry_on StandardError, wait: :polynomially_longer, attempts: 5

  def perform(audit_log_id)
    audit_log = AuditLog.find_by(id: audit_log_id)
    return if audit_log.nil? || audit_log.slack_channel.blank? || audit_log.slack_posted?

    Service::SlackConnector.send_slack_message(
      audit_log.slack_message,
      audit_log.slack_channel
    )
    audit_log.set(slack_posted: true)
  rescue => error
    audit_log&.set(slack_posted: false)
    raise error
  end
end
