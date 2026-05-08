class VolunteerTask
  include Mongoid::Document
  include Mongoid::Timestamps
  include Service::SlackConnector

  store_in collection: 'volunteer_tasks'

  # Task details
  field :task_number,  type: Integer               # auto-assigned sequential ID
  field :title,        type: String
  field :description,  type: String
  field :credit_value, type: Float, default: 1.0

  # Optional shop association
  field :shop_id,      type: BSON::ObjectId, default: nil

  # Lifecycle status
  # available  — posted, open for claiming
  # claimed    — a member has claimed it, pending completion
  # pending    — completed by member, awaiting admin/RM verification
  # completed  — verified and credit issued
  # cancelled  — removed from the board
  field :status,         type: String, default: 'available'

  field :created_by_id,    type: BSON::ObjectId
  field :claimed_by_id,    type: BSON::ObjectId, default: nil
  field :claimed_at,       type: Time,            default: nil
  field :completed_at,     type: Time,            default: nil
  field :verified_by_id,   type: BSON::ObjectId,  default: nil
  field :rejection_reason, type: String,           default: nil

  VALID_STATUSES = %w[available claimed pending completed cancelled].freeze

  validates :title,        presence: true
  validates :description,  presence: true
  validates :credit_value, numericality: { greater_than: 0 }
  validates_inclusion_of :status, in: VALID_STATUSES

  # Max credit check only runs on creation so existing tasks are never
  # invalidated if the admin changes the setting later.
  validate :credit_value_within_max, on: :create

  before_create :assign_task_number

  index({ status: 1 })
  index({ claimed_by_id: 1 })
  index({ task_number: 1 }, { unique: true })

  # ── Scopes ────────────────────────────────────────────────────────────────

  scope :available, -> { where(status: 'available') }
  scope :active,    -> { where(:status.in => %w[available claimed pending]) }

  # ── Settings ──────────────────────────────────────────────────────────────

  def self.max_credit_value
    (SystemConfig.get('volunteer_task_max_credit') ||
      ENV.fetch('VOLUNTEER_TASK_MAX_CREDIT', 2.0)).to_f
  end

  # Find a task by its sequential task number
  def self.find_by_number(number)
    find_by(task_number: number.to_i)
  end

  # ── Instance Methods ──────────────────────────────────────────────────────

  def display_number
    "##{task_number}"
  end

  def shop
    Shop.find(shop_id) if shop_id
  end

  def created_by
    Member.find(created_by_id) if created_by_id
  end

  def claimed_by
    Member.find(claimed_by_id) if claimed_by_id
  end

  def verified_by
    Member.find(verified_by_id) if verified_by_id
  end

  def claim!(member)
    raise Error::Forbidden.new unless status == 'available'
    update!(
      status:        'claimed',
      claimed_by_id: member.id,
      claimed_at:    Time.now
    )
  end

  def mark_pending!(member)
    raise Error::Forbidden.new unless status == 'claimed' && claimed_by_id == member.id
    update!(status: 'pending', completed_at: Time.now)
  end

  def complete!(verifier)
    raise Error::Forbidden.new if verifier.id == claimed_by_id
    raise Error::Forbidden.new unless status == 'pending'

    update!(status: 'completed', verified_by_id: verifier.id)

    credit = VolunteerCredit.create!(
      member_id:    claimed_by_id,
      issued_by_id: verifier.id,
      task_id:      id,
      description:  "Completed bounty task: #{title}",
      credit_value: credit_value,
      status:       'approved'
    )
    credit.send(:notify_member_credit_awarded)
    credit.send(:check_discount_threshold!)
  end

  # Release a claimed task back to available.
  def release!(admin, reason)
    raise Error::Forbidden.new unless status == 'claimed'
    raise Error::Forbidden.new if admin.id == claimed_by_id

    former_claimant_id = claimed_by_id

    update!(
      status:           'available',
      claimed_by_id:    nil,
      claimed_at:       nil,
      rejection_reason: reason
    )

    notify_member_task_released(former_claimant_id, reason)
  end

  # Reject a pending task.
  def reject_pending!(admin, reason)
    raise Error::Forbidden.new unless status == 'pending'
    raise Error::Forbidden.new if admin.id == claimed_by_id

    former_claimant_id = claimed_by_id

    update!(
      status:           'available',
      claimed_by_id:    nil,
      claimed_at:       nil,
      completed_at:     nil,
      rejection_reason: reason
    )

    notify_member_task_rejected(former_claimant_id, reason)
  end

  def cancel!
    update!(status: 'cancelled')
  end

  private

  # Auto-assign the next sequential task number on create.
  # Uses SystemConfig as an atomic-enough counter for low-volume use.
  def assign_task_number
    counter_key = 'volunteer_task_counter'
    current     = SystemConfig.get(counter_key).to_i
    next_number = current + 1
    SystemConfig.set(counter_key, next_number.to_s)
    self.task_number = next_number
  end

  def credit_value_within_max
    max = VolunteerTask.max_credit_value
    if credit_value && credit_value > max
      errors.add(:credit_value, "cannot exceed #{max} credits (current maximum). Contact an admin to increase the limit.")
    end
  end

  def notify_member_task_released(member_id, reason)
    slack_user = SlackUser.find_by(member_id: member_id)
    return unless slack_user

    ::Service::SlackConnector.send_slack_message(
      "ℹ️ Your claim on *#{title}* (#{display_number}) has been released by an admin. " \
      "Reason: #{reason}. The task is now available for others to claim.",
      slack_user.slack_id
    )
  rescue => e
    Honeybadger.notify(e) if defined?(Honeybadger)
  end

  def notify_member_task_rejected(member_id, reason)
    slack_user = SlackUser.find_by(member_id: member_id)
    return unless slack_user

    ::Service::SlackConnector.send_slack_message(
      "ℹ️ Your completion of *#{title}* (#{display_number}) was not verified. " \
      "Reason: #{reason}. The task is now available for reclaiming.",
      slack_user.slack_id
    )
  rescue => e
    Honeybadger.notify(e) if defined?(Honeybadger)
  end
end
