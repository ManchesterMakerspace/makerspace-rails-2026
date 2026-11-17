class MembershipPaidBackfillRun
  include Mongoid::Document
  include Mongoid::Timestamps
  store_in collection: 'membership_paid_backfill_runs'
  field :cutoff, type: Time
  field :mode, type: String
  field :cursor, type: BSON::ObjectId
  field :counts, type: Hash, default: {}
  field :completed_at, type: Time
  validates :cutoff, presence: true
end
