class VolunteerEventReminderJob < ApplicationJob
  queue_as :default

  def perform
    stale_events.each { |event| send_reminder(event) }
    SystemConfig.record_run('volunteer_event_reminder', success: true)
  rescue => e
    SystemConfig.record_run('volunteer_event_reminder', success: false)
    Honeybadger.notify(e) if defined?(Honeybadger)
    raise
  end

  private

  def stale_events
    VolunteerEvent.where(status: 'open', :event_date.ne => nil, :event_date.lt => Date.today)
  end

  def send_reminder(event)
    days_overdue = (Date.today - event.event_date).to_i
    ::Service::SlackConnector.send_slack_message(
      "⏰ *#{event.title}* (#{event.display_number}) was scheduled for " \
      "#{event.event_date.strftime('%m/%d/%Y')} (#{days_overdue} day#{'s' unless days_overdue == 1} ago) " \
      "and is still open with #{event.attendee_count} checked-in attendee#{'s' unless event.attendee_count == 1}. " \
      "Close it to issue credits.",
      VolunteerCredit.pending_slack_channel
    )
  rescue => e
    Honeybadger.notify(e) if defined?(Honeybadger)
  end
end
