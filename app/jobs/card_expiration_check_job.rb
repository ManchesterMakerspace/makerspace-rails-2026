class CardExpirationCheckJob < ApplicationJob
  queue_as :default

  def perform
    Rails.application.load_tasks unless Rake::Task.task_defined?('card_on_file_expiration_check')
    Rake::Task['card_on_file_expiration_check'].reenable
    Rake::Task['card_on_file_expiration_check'].invoke
    SystemConfig.record_run('card_expiration_check', success: true)
  rescue => error
    SystemConfig.record_run('card_expiration_check', success: false)
    Honeybadger.notify('CardExpirationCheckJob failed', context: { error: error.message }) if defined?(Honeybadger)
    raise
  end
end
