class EventbriteWebhookDelivery
  include Mongoid::Document
  include Mongoid::Timestamps
  store_in collection: 'eventbrite_webhook_deliveries'
  field :resource, type: Hash
  field :action, type: String
  field :attempts, type: Integer, default: 0
  field :due_at, type: Time, default: -> { Time.current }
  field :lease_until, type: Time
  field :lease_token, type: String
  field :completed_at, type: Time
  field :failed_at, type: Time
  field :last_error, type: String
  field :expires_at, type: Time
  index({ completed_at: 1, failed_at: 1, due_at: 1, lease_until: 1 })
  index({ expires_at: 1 }, expire_after_seconds: 0)
end
