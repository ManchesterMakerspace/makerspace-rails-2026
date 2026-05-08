class VolunteerCredit
  include Mongoid::Document
  include Mongoid::Timestamps
  include Service::SlackConnector

  store_in collection: 'volunteer_credits'

  # Core associations
  field :member_id,     type: BSON::ObjectId
  field :issued_by_id,  type: BSON::ObjectId  # admin/RM who awarded or verified
  field :task_id,       type: BSON::ObjectId, default: nil  # nil for one-off credits

  # Credit details
  field :description,   type: String
  field :credit_value,  type: Float, default: 1.0

  # Lifecycle status
  # pending     — submitted, awaiting approval
  # approved    — verified, counts toward threshold
  # rejected    — denied by admin/RM
  field :status,        type: String, default: 'pending'

  # Discount tracking — populated when this credit contributes to triggering a discount
  field :discount_applied,    type: Boolean, default: false
  field :discount_applied_at, type: Time,    default: nil

  validates :member_id,    presence: true
  validates :description,  presence: true
  validates :credit_value, numericality: { greater_than: 0 }
  validates_inclusion_of :status, in: %w[pending approved rejected]

  validate :approver_is_not_self

  index({ member_id: 1 })
  index({ status: 1 })
  index({ created_at: 1 })

  # ── Scopes ────────────────────────────────────────────────────────────────

  scope :approved,  -> { where(status: 'approved') }
  scope :pending,   -> { where(status: 'pending') }
  scope :rejected,  -> { where(status: 'rejected') }
  scope :this_year, -> { where(:created_at.gte => Time.now.beginning_of_year) }

  # ── Class Methods ─────────────────────────────────────────────────────────

  # Total approved credits earned by a member in the current calendar year
  def self.year_count_for(member_id)
    approved.this_year.where(member_id: member_id).sum(:credit_value).to_f
  end

  # Number of discounts already applied to a member this calendar year
  def self.discounts_applied_this_year_for(member_id)
    threshold = [credits_per_discount, 1].max.to_f
    applied_sum = approved.this_year
                          .where(member_id: member_id, discount_applied: true)
                          .sum(:credit_value).to_f
    (applied_sum / threshold).floor
  end

  # Settings-backed thresholds with ENV fallbacks
  def self.credits_per_discount
    (SystemConfig.get('volunteer_credits_per_discount') ||
      ENV.fetch('VOLUNTEER_CREDITS_PER_DISCOUNT', 8)).to_f
  end

  def self.max_discounts_per_year
    (SystemConfig.get('volunteer_max_discounts_per_year') ||
      ENV.fetch('VOLUNTEER_MAX_DISCOUNTS_PER_YEAR', 2)).to_i
  end

  def self.discount_amount
    (SystemConfig.get('volunteer_discount_amount') ||
      ENV.fetch('VOLUNTEER_DISCOUNT_AMOUNT', '0')).to_f
  end

  def self.pending_slack_channel
    SystemConfig.get('volunteer_pending_slack_channel') ||
      ENV.fetch('VOLUNTEER_PENDING_SLACK_CHANNEL', 'general')
  end

  # ── Instance Methods ──────────────────────────────────────────────────────

  def member
    Member.find(member_id)
  end

  def issued_by
    Member.find(issued_by_id) if issued_by_id
  end

  def task
    VolunteerTask.find(task_id) if task_id
  end

  def approve!(approver)
    raise Error::Forbidden.new if approver.id == member_id
    update!(status: 'approved', issued_by_id: approver.id)
    notify_member_credit_awarded
    check_discount_threshold!
  end

  def reject!(approver)
    raise Error::Forbidden.new if approver.id == member_id
    update!(status: 'rejected', issued_by_id: approver.id)
  end

  private

  def approver_is_not_self
    if issued_by_id && issued_by_id == member_id && status == 'approved'
      errors.add(:issued_by_id, 'cannot approve their own credit')
    end
  end

  # DM the member when their credit is approved/awarded
  def notify_member_credit_awarded
    m = member
    year_total = VolunteerCredit.year_count_for(m.id)
    slack_user = SlackUser.find_by(member_id: m.id)
    return unless slack_user

    ::Service::SlackConnector.send_slack_message(
      "🌟 You've been awarded a volunteer credit for: #{description}. " \
      "You now have #{year_total} credit#{'s' if year_total != 1.0} this year.",
      slack_user.slack_id
    )
  rescue => e
    Honeybadger.notify(e) if defined?(Honeybadger)
  end

  # After approval, check if member has hit the discount threshold.
  # Earned members never get discounts — credits still log for recognition.
  # Members who have hit the annual discount cap keep earning credits
  # but no new discount is triggered.
  def check_discount_threshold!
    m = member
    return if EarnedMembership.where(member_id: m.id).exists?

    year_total     = VolunteerCredit.year_count_for(m.id)
    discounts_used = VolunteerCredit.discounts_applied_this_year_for(m.id)
    threshold      = VolunteerCredit.credits_per_discount
    max_discounts  = VolunteerCredit.max_discounts_per_year

    return if discounts_used >= max_discounts
    return unless year_total >= threshold * (discounts_used + 1)

    # Mark the credits in this discount batch (oldest first, up to threshold value)
    remaining = threshold
    VolunteerCredit.approved.this_year
                   .where(member_id: member_id, discount_applied: false)
                   .order_by(created_at: :asc)
                   .each do |credit|
      break if remaining <= 0
      credit.update!(discount_applied: true, discount_applied_at: Time.now)
      remaining -= credit.credit_value
    end

    notify_discount_applied(m)

    # TODO Phase 2: apply Braintree discount here
    # BraintreeService::VolunteerDiscount.apply(m, VolunteerCredit.discount_amount)
  end

  # DM the member and notify the treasurer channel when a discount is triggered
  def notify_discount_applied(m)
    return if VolunteerCredit.discount_amount == 0.0
    discount_amount = VolunteerCredit.discount_amount
    threshold       = VolunteerCredit.credits_per_discount

    # DM the member
    slack_user = SlackUser.find_by(member_id: m.id)
    if slack_user
      ::Service::SlackConnector.send_slack_message(
        "🎉 You've reached #{threshold} credits and earned a discount on your next billing cycle!",
        slack_user.slack_id
      )
    end

    # Notify treasurer channel
    amount_str = discount_amount > 0 ? "$#{format('%.2f', discount_amount)} off" : 'a discount'
    ::Service::SlackConnector.send_slack_message(
      "💰 Volunteer discount applied for *#{m.fullname}* — #{amount_str} their next billing cycle.",
      ::Service::SlackConnector.treasurer_channel
    )
  rescue => e
    Honeybadger.notify(e) if defined?(Honeybadger)
  end
end
