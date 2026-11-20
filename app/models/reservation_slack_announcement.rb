class ReservationSlackAnnouncement
  include Mongoid::Document
  include Mongoid::Timestamps

  store_in collection: 'reservation_slack_announcements'
  field :day, type: String
  field :mode, type: String
  field :channel_id, type: String
  field :ts, type: String
  field :fingerprint, type: String
  field :shop_ids, type: Array, default: []
  field :canvas_ids, type: Hash, default: {}
  field :empty_agenda, type: Boolean, default: false
  field :deleted_at, type: Time
  field :client_msg_id, type: String, default: -> { SecureRandom.uuid }
  field :sending_at, type: Time
  field :attempts, type: Integer, default: 0
  field :retry_at, type: Time
  field :last_error, type: String

  validates :day, :mode, :channel_id, presence: true
  validates :mode, inclusion: { in: %w[production test] }
  index({ day: 1, mode: 1, channel_id: 1 }, unique: true)
end
