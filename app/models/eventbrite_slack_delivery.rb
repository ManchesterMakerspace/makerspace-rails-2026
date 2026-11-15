class EventbriteSlackDelivery
  include Mongoid::Document
  include Mongoid::Timestamps
  store_in collection: 'eventbrite_slack_deliveries'
  field :organization_id, type: String
  field :scope_id, type: String
  field :kind, type: String
  field :day, type: String, default: ''
  field :mode, type: String
  field :event_ids, type: Array, default: []
  field :revision, type: Integer, default: 0
  field :delivered_revision, type: Integer, default: -1
  field :channel, type: String
  field :ts, type: String
  field :client_msg_id, type: String, default: -> { SecureRandom.uuid }
  field :due_at, type: Time, default: -> { Time.current }
  field :attempts, type: Integer, default: 0
  field :failed_at, type: Time
  field :last_error, type: String
  field :sending_at, type: Time
  field :expired, type: Boolean, default: false
  validates :organization_id, :scope_id, :kind, :mode, presence: true
  validates :kind, inclusion: { in: %w[publication reminder] }
  index({ organization_id: 1, scope_id: 1, kind: 1, day: 1, mode: 1 }, unique: true)
  index({ failed_at: 1, due_at: 1 })
  index({ organization_id: 1, event_ids: 1 })
end
