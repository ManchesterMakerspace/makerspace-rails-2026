class VolunteerEventReminderJob < ApplicationJob
  queue_as :default

  def perform
    now = Time.current
    reminder_tasks(now).each { |task| Service::VolunteerApprovalReminder.remind!(task, now: now) }
    reminder_events(now).each { |event| Service::VolunteerApprovalReminder.remind!(event, now: now) }
    SystemConfig.record_run('volunteer_event_reminder', success: true)
  rescue => e
    SystemConfig.record_run('volunteer_event_reminder', success: false)
    Service::ErrorReporter.notify(e)
    raise
  end

  private

  def reminder_tasks(now)
    VolunteerTask.any_of(
      { status: 'pending', completed_at: { '$ne' => nil, '$lt' => now - Service::VolunteerApprovalReminder::WAIT_DAYS.days } },
      *unfinished_notifications
    )
  end

  def reminder_events(now)
    VolunteerEvent.any_of(
      { status: 'open', event_date: { '$ne' => nil, '$lt' => now.to_date - Service::VolunteerApprovalReminder::WAIT_DAYS } },
      *unfinished_notifications
    )
  end

  def unfinished_notifications
    [
      { 'approval_notification.finalized' => false },
      { approval_notification_history: { '$elemMatch' => { 'finalized' => false } } }
    ]
  end
end
