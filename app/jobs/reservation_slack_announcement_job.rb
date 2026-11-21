class ReservationSlackAnnouncementJob < ApplicationJob
  queue_as :default
  retry_on StandardError, wait: :polynomially_longer, attempts: 5

  # This notification is recoverable by the scheduler. A queue outage must not
  # make an already-persisted reservation/catalog edit appear to have failed.
  def self.enqueue_today
    perform_later(Time.current.in_time_zone(ReservationService::ZONE).to_date.iso8601)
  rescue => error
    Rails.logger.error("[ReservationSlackAnnouncementEnqueue] #{error.class}")
    begin
      Service::ErrorReporter.notify(error, context: { phase: 'enqueue reservation Slack announcements' })
    rescue => reporting_error
      Rails.logger.error("[ReservationSlackAnnouncementEnqueue] Reporting failed: #{reporting_error.class}")
    end
    nil
  end

  def perform(day = nil)
    result = Service::ReservationSlackAnnouncements.sync!(date: day)
    SystemConfig.record_run('reservation_slack_announcements', success: true) unless result == :skipped
  rescue => error
    SystemConfig.record_run('reservation_slack_announcements', success: false)
    Service::ErrorReporter.notify(error, context: { phase: 'reservation Slack announcements' })
    raise
  end
end
