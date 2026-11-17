class MembershipPaidBackfillReport
  include Mongoid::Document
  include Mongoid::Timestamps
  store_in collection: 'membership_paid_backfill_reports'
  field :run_id, type: BSON::ObjectId
  field :member_id, type: BSON::ObjectId
  field :mode, type: String
  field :status, type: String
  field :estimated, type: Boolean
  field :months, type: Integer
  field :balance, type: String
  field :revision, type: Integer
  field :issues, type: Array, default: []
  field :sources, type: Array, default: []
  index({ run_id: 1, member_id: 1 }, unique: true)
  index({ run_id: 1, status: 1 })
end
