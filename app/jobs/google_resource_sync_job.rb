class GoogleResourceSyncJob < ApplicationJob
  queue_as :default

  def perform(resource_type, resource_id)
    klass = resource_type.to_s.constantize
    record = klass.find(resource_id)
    category = klass == Shop ? "CONFERENCE_ROOM" : "OTHER"
    Service::GoogleWorkspace.ensure_resource!(record, category)
  rescue => error
    Honeybadger.notify(error) if defined?(Honeybadger)
    Rails.logger.warn("Google resource sync failed for #{resource_type}/#{resource_id}: #{error.message}")
  end
end
