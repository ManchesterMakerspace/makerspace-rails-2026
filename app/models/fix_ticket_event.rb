# Actor identities are internal. All output goes through FixTicketPresenter.
class FixTicketEvent
  include Mongoid::Document
  field :ticket_id, type: BSON::ObjectId
  field :actor_id, type: BSON::ObjectId
  field :kind, type: String
  field :note, type: String
  field :field_changes, type: Hash, default: {}
  field :recipients, type: Array, default: []
  field :created_at, type: Time, default: -> { Time.current }
  field :delivered, type: Hash, default: {}
  field :central_enabled, type: Boolean, default: -> { ENV['SLACK_TICKETS_CHANNEL'].present? }
  field :delivery_attempts, type: Hash, default: {}
  field :delivery_error, type: String
  field :completed_at, type: Time
  field :revision, type: Integer
  index({ ticket_id: 1, revision: 1 }, unique: true)
  index({ completed_at: 1, created_at: 1 })
end
