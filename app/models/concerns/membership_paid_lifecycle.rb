module MembershipPaidLifecycle
  extend ActiveSupport::Concern

  included do
    field :continuous_paid_membership_months, type: Integer, default: 0
    field :continuous_paid_membership_balance, type: BigDecimal, default: -> { BigDecimal('0') }
    field :continuous_paid_membership_streak_id, type: String, default: -> { SecureRandom.uuid }
    field :continuous_paid_membership_revision, type: Integer, default: 0
    field :continuous_paid_membership_estimated, type: Mongoid::Boolean, default: true
    field :continuous_paid_membership_backfilled_at, type: Time
    field :continuous_paid_membership_backfill_run_id, type: String
    field :continuous_paid_membership_reset_key, type: String

    index({ expirationTime: 1, continuous_paid_membership_balance: 1 })
    before_create :initialize_paid_membership_history
    around_save :with_paid_membership_lifecycle
  end

  private

  def initialize_paid_membership_history
    # New accounts have complete live history from creation. A legacy document
    # missing this field stays estimated even if an unrelated save adds defaults.
    self.continuous_paid_membership_estimated = false
  end

  def with_paid_membership_lifecycle
    if persisted? && (expirationTime_changed? || status_changed?)
      MembershipPaidCredit.transaction(attempts: 1) do
        MembershipPaidCredit.before_member_change!(self)
        yield
      end
    else
      yield
    end
  end
end
