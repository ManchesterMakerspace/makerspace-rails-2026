class MembershipPaidCreditEntry
  include Mongoid::Document
  include Mongoid::Timestamps::Created

  store_in collection: 'membership_paid_credit_entries'

  field :member_id, type: BSON::ObjectId
  field :streak_id, type: String
  field :source_key, type: String
  field :invoice_id, type: BSON::ObjectId
  field :action, type: String
  field :action_key, type: String
  field :months, type: BigDecimal, default: -> { BigDecimal('0') }
  field :balance_delta, type: BigDecimal, default: -> { BigDecimal('0') }
  field :paid_amount, type: BigDecimal
  field :currency, type: String
  field :refunded_amount, type: BigDecimal, default: -> { BigDecimal('0') }
  field :deducted_months, type: BigDecimal, default: -> { BigDecimal('0') }
  field :operation_revision, type: Integer, default: 0
  field :occurred_at, type: Time
  field :coverage_start, type: Time
  field :coverage_end, type: Time
  field :estimated, type: Boolean, default: false
  field :details, type: Hash, default: {}

  index({ source_key: 1, member_id: 1, action: 1, action_key: 1 }, unique: true)
  index({ member_id: 1, streak_id: 1, occurred_at: 1 })
  index({ invoice_id: 1, action: 1 })

  validates :member_id, :streak_id, :source_key, :action, :action_key, :occurred_at, presence: true
  validates :action, inclusion: { in: %w[application refund reversal reset admin_adjustment] }
end
