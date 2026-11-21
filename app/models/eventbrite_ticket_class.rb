class EventbriteTicketClass
  include EventbriteRecord
  store_in collection: 'eventbrite_ticket_classes'
  field :event_id, type: String
  field :name, type: String
  field :cost, type: Hash, default: {}
  field :free, type: Boolean
  field :quantity_total, type: Integer
  index({ organization_id: 1, event_id: 1 })

  after_save :invalidate_changed_display_cache
  after_destroy :invalidate_display_cache

  private

  def invalidate_changed_display_cache
    invalidate_display_cache if (previous_changes.keys & %w[_id organization_id eventbrite_id name]).any?
  end

  def invalidate_display_cache
    EventbriteIntegration::DisplayCache.invalidate_ticket_classes
  end
end
