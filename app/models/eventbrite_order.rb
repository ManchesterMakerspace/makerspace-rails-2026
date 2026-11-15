class EventbriteOrder
  include EventbriteRecord
  store_in collection: 'eventbrite_orders'
  field :event_id, type: String
  field :name, type: String
  field :email, type: String
  field :status, type: String
  field :costs, type: Hash, default: {}
  field :refunded_at, type: Time
  field :refund_evidence, type: Array, default: []
  index({ organization_id: 1, event_id: 1 })
end
