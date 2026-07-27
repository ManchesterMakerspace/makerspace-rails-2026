class DatabaseBackupJob < ApplicationJob
  queue_as :integrations
  retry_on StandardError, wait: :polynomially_longer, attempts: 5

  def perform
    MemoryHeavyJobLock.with_lock(expires_in: 1.hour) do
      Rails.application.load_tasks
      begin
        Rake::Task["backup"].reenable
        Rake::Task["backup"].invoke
        SystemConfig.record_run("db_backup", success: true)
      rescue => e
        SystemConfig.record_run("db_backup", success: false)
        Honeybadger.notify("DatabaseBackupJob failed", context: { error: e.message })
        raise e
      end
    end
  end
end
