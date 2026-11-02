class MemberReminderJob < ApplicationJob
  queue_as :default

  def perform
    Service::MemberReminders.run!
    SystemConfig.record_run('member_reminders', success: true)
  rescue => error
    SystemConfig.record_run('member_reminders', success: false)
    Service::ErrorReporter.notify('MemberReminderJob failed', context: { error: error.message })
    raise
  end
end
