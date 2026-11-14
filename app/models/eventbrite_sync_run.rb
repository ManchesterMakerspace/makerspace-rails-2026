class EventbriteSyncRun
  include Mongoid::Document
  include Mongoid::Timestamps
  store_in collection: 'eventbrite_sync_runs'
  field :kind, type: String
  field :organizations, type: Array
  field :filters, type: Hash, default: {}
  field :progress, type: Hash, default: {}
  field :started_at, type: Time, default: -> { Time.current }
  field :completed_at, type: Time
  field :last_error, type: String
  field :processed, type: Integer, default: 0
  field :skipped, type: Integer, default: 0
  field :failed, type: Integer, default: 0
  index({ kind: 1, completed_at: -1 })
end
