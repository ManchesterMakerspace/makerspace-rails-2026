class EventbriteAttendee
  include EventbriteRecord
  store_in collection: 'eventbrite_attendees'
  field :event_id, type: String
  field :order_id, type: String
  field :ticket_class_id, type: String
  field :name, type: String
  field :email, type: String
  field :status, type: String
  field :refunded, type: Boolean, default: false
  field :member_id, type: BSON::ObjectId
  field :matched_email, type: String
  field :linked_at, type: Time
  field :link_conflict, type: Boolean, default: false
  index({ email: 1, member_id: 1 })
  index({ member_id: 1, organization_id: 1, order_id: 1 })
  index({ organization_id: 1, event_id: 1, order_id: 1 })
end
