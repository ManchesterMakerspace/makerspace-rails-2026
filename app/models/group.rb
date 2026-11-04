class Group
  include Mongoid::Document
  include InvoiceableResource
  include Service::SlackConnector

  # Adults a household covers when its plan does not say (see InvoiceOption#household_size).
  DEFAULT_SIZE = 2

  field :groupRep            # primary member's fullname (display only)
  field :groupName, type: String  # primary member's MongoDB ID (unique key)
  field :expiry, type: Integer    # expiration in ms, propagated to all household members
  field :subscription_id, type: String
  field :subscription, type: Boolean, default: false

  belongs_to :member, primary_key: 'fullname', foreign_key: "groupRep"
  has_many :active_members, class_name: "Member", inverse_of: :group, primary_key: 'groupName', foreign_key: "groupName"

  # Override member to use direct ID lookup since fullname is not a stored field
  def member
    Member.find(self.groupName) rescue nil
  end

  validates :groupName, presence: true, uniqueness: true
  validates :groupRep, presence: true
  validate :primary_on_household_plan, on: :create

  after_update :update_active_members, :handle_reservation_subscription_change
  after_create :update_active_members

  index({ groupName: 1 }, {
    unique: true,
    partial_filter_expression: { groupName: { '$type' => 'string' } }
  })

  def group_display_name
    "#{groupRep}'s Household"
  end

  # The primary's household-plan member invoices, newest first.
  def self.household_invoices_for(primary)
    return Invoice.none unless primary

    Invoice.where(resource_class: "member", resource_id: primary.id.to_s, :plan_id => /household/i).order_by(created_at: :desc)
  end

  # Whether the primary's household payment has been accepted: the most recent household-plan invoice that was settled is
  # not refunded and has no open dispute, and the primary's paid time has not run out. A new household whose payment is held
  # until the first fob has no expiry yet and counts. Gates the primary's own invitations only; an admin is never blocked by it.
  def self.payment_accepted_for?(primary)
    settled = household_invoices_for(primary).detect { |invoice| invoice.settled_at.present? }
    return false unless settled
    return false if settled.refunded
    return false if settled.dispute_requested.present? && !settled.dispute_settled

    expiry = primary.expirationTime
    expiry.nil? || expiry > (Time.now.to_i * 1000)
  end

  # How many adults the primary's household plan covers.
  def self.size_for(primary)
    plan_id = household_invoices_for(primary).first&.plan_id
    option = plan_id.present? ? InvoiceOption.where(plan_id: plan_id).first : nil
    option&.effective_household_size || DEFAULT_SIZE
  end

  def payment_accepted?
    self.class.payment_accepted_for?(member)
  end

  def size
    self.class.size_for(member)
  end

  def secondary_members
    active_members.where(:id.ne => groupName)
  end

  # The primary and the linked secondaries.
  def members_count
    1 + secondary_members.count
  end

  def seats_used
    members_count
  end

  def full?(ignoring_invitation: nil)
    seats_used >= size
  end

  # Links a secondary. Refuses a full household and an address that does not match the primary's, unless an admin gives a
  # reason to override the address. Returns the override details when one was used (for the audit entry), else nil.
  # invitation: the invitation this join comes from; its own seat does not count against the household.
  def add_subordinate(subordinate_member, address_override_reason: nil, invitation: nil)
    if full?(ignoring_invitation: invitation)
      raise ::Error::UnprocessableEntity.new(
        "This household is full (#{seats_used} of #{size} adults). Remove someone, or move to a larger household plan, before adding another."
      )
    end

    override = validate_address_match!(subordinate_member, address_override_reason)
    subordinate_member.update_attributes!({
      groupName: self.groupName,
      expirationTime: self.expiry  # directly set expiry regardless of current state
    })
    update_active_members
    override
  end

  def remove_subordinate(subordinate_member)
    # Revert to their own invoice's expiration if available
    own_invoice = Invoice.where(
      resource_class: "member",
      resource_id: subordinate_member.id.to_s
    ).where(:plan_id.nin => [nil, ""], :plan_id.not => /household/)
     .order_by(created_at: :desc).first

    own_expiration = own_invoice&.due_date ? (own_invoice.due_date.to_i * 1000) : nil
    subordinate_member.update_attributes!({ groupName: nil, expirationTime: own_expiration })
  end

  # InvoiceableResource interface
  def expiration_attr
    :expiry
  end

  def base_slack_message
    "#{groupRep}'s household membership"
  end

  def update_expiration(new_expiration)
    household_key = groupName.to_s
    member_ids = (Member.where(groupName: household_key).pluck(:id) + [member&.id]).compact.uniq

    Group.collection.find(_id: id).update_one("$set" => { expiry: new_expiration })
    self.expiry = new_expiration
    Member.collection.find(_id: { "$in" => member_ids }).update_many(
      "$set" => { expirationTime: new_expiration, groupName: household_key }
    )
    Card.where(:member_id.in => member_ids).update_all(expiry: new_expiration)
    Service::ToolCheckoutSlackCanvas.enqueue_for_members(member_ids)

    true
  end

  # Emit to Member & Management channels on renewal. Matches the pattern
  # used by Member/Rental — queued via enque_message with distinct
  # uniquifiers per recipient, not the synchronous send_slack_message this
  # codebase has been moving away from (see #91).
  def send_renewal_slack_message(current_user = nil)
    slack_user = SlackUser.find_by(member_id: member.id) if member
    unless slack_user.nil?
      enque_message(
        get_renewal_slack_message,
        slack_user.slack_id,
        ::Service::SlackConnector.request_caller_id("send_renewal_slack_message.member.#{id}")
      )
    end
    enque_message(
      get_renewal_slack_message(current_user),
      ::Service::SlackConnector.members_relations_channel,
      ::Service::SlackConnector.request_caller_id("send_renewal_slack_message.management.#{id}")
    )
  end

  def send_renewal_reversal_slack_message
    slack_user = SlackUser.find_by(member_id: member.id) if member
    unless slack_user.nil?
      enque_message(
        get_renewal_reversal_slack_message,
        slack_user.slack_id,
        ::Service::SlackConnector.request_caller_id("send_renewal_reversal_slack_message.member.#{id}")
      )
    end
    enque_message(
      get_renewal_reversal_slack_message,
      ::Service::SlackConnector.members_relations_channel,
      ::Service::SlackConnector.request_caller_id("send_renewal_reversal_slack_message.management.#{id}")
    )
  end

  def remove_subscription
    update_attributes!({ subscription_id: nil, subscription: false })
  end

  def handle_reservation_subscription_change
    subscription_change = previous_changes["subscription"]
    subscription_id_change = previous_changes["subscription_id"]
    ended = (subscription_change&.first == true && subscription != true) ||
      (subscription_id_change&.first.present? && subscription_id.blank?)
    return unless ended

    ReservationLifecycleService.cancel_beyond_membership!(
      self,
      reason: "Household recurring membership was cancelled"
    )
  rescue => error
    Rails.logger.error(
      "[ReservationCleanup] group_id=#{id} type=subscription_ended " \
      "error=#{error.class}: #{error.message}"
    )
    Honeybadger.notify(error) if defined?(Honeybadger)
    ReservationMembershipCleanupJob.perform_later(
      id.to_s,
      "group_subscription_ended",
      "Group"
    )
  end

  private

  def update_active_members
    self.active_members.each { |m| m.verify_group_expiry }
    self.member.verify_group_expiry if self.member
  end

  def primary_on_household_plan
    primary = self.member
    return unless primary
    invoice = Invoice.where(resource_class: "member", resource_id: primary.id.to_s)
                     .order_by(created_at: :desc).first
    unless invoice&.plan_id&.include?("household")
      errors.add(:base, "Primary member must be on a household membership plan")
    end
  end

  # Forgiving about case, punctuation and "St"/"Street" style words, strict about the street number, street name and postal
  # code (Service::AddressMatch). Returns nil on a match, the override details when an admin gave a reason, else raises.
  def validate_address_match!(subordinate_member, override_reason = nil)
    primary = self.member
    return nil unless primary
    return nil if ::Service::AddressMatch.members_match?(primary, subordinate_member)

    primary_text = ::Service::AddressMatch.describe(primary)
    secondary_text = ::Service::AddressMatch.describe(subordinate_member)
    if override_reason.to_s.strip.present?
      return { reason: override_reason.to_s.strip, household_address: primary_text, member_address: secondary_text }
    end

    raise ::Error::UnprocessableEntity.new(
      "Address mismatch: the second adult's address (#{secondary_text}) does not match the household address " \
      "(#{primary_text}). The street number, street name and postal code must match."
    )
  end
end
