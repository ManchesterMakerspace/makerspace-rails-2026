class EventbriteInventoryRefreshJob < ApplicationJob
  def perform(id)
    event = EventbriteEvent.find(id)
    due = event.inventory_refresh_at
    return unless due && due <= Time.current
    return unless EventbriteIntegration::Configuration.organization_allowed?(event.organization_id)
    EventbriteIntegration::Announcements.new.refresh(event)
    EventbriteEvent.where(id: event.id, inventory_refresh_at: due).update_all(inventory_refresh_at: nil)
  rescue EventbriteIntegration::Client::Deferred => error
    EventbriteEvent.where(id: id, inventory_refresh_at: due).update_all(inventory_refresh_at: Time.current + error.delay)
  rescue StandardError => error
    EventbriteEvent.where(id: id, inventory_refresh_at: due).update_all(inventory_refresh_at: 5.minutes.from_now)
    Rails.logger.error("Eventbrite inventory refresh #{id}: #{error.class.name}")
  end
end
