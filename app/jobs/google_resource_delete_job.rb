class GoogleResourceDeleteJob < ApplicationJob
  queue_as :default

  def perform(resource_id)
    Service::GoogleWorkspace.delete_resource!(resource_id)
  rescue => error
    Honeybadger.notify(error) if defined?(Honeybadger)
    Rails.logger.warn("Google resource deletion failed for #{resource_id}: #{error.message}")
  end
end
