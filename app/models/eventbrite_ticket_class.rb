class EventbriteTicketClass
  include EventbriteRecord
  store_in collection: 'eventbrite_ticket_classes'
  field :event_id, type: String
  field :name, type: String
  field :cost, type: Hash, default: {}
  field :free, type: Boolean
  field :quantity_total, type: Integer
  index({ organization_id: 1, event_id: 1 })
end
