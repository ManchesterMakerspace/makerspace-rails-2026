class CheckoutApproverRequest
  include Mongoid::Document

  belongs_to :member
  belongs_to :tool

  field :status, type: String, default: "open"
  field :request_date, type: Time, default: -> { Time.current }
  field :note, type: String
  field :decision_note, type: String
  field :decided_at, type: Time

  index({ member_id: 1, tool_id: 1, status: 1 }, unique: true,
    partial_filter_expression: { status: "open" })

  validates :member, :tool, presence: true
  validates :status, inclusion: { in: %w[open approved declined revoked] }
  validates :note, :decision_note, length: { maximum: 128 }, allow_blank: true
  validate :member_has_active_checkout, on: :create
  validate :member_is_eligible, on: :create
  validate :request_is_not_duplicate, on: :create

  def open?
    status == "open"
  end

  private

  def member_has_active_checkout
    errors.add(:member, "must have an active checkout for this tool") unless
      member && tool && ToolCheckout.where(member_id: member.id, tool_id: tool.id, revoked_at: nil).exists?
  end

  def member_is_eligible
    errors.add(:member, "must be in good standing") unless member&.valid_for_checkout_request?
  end

  def request_is_not_duplicate
    errors.add(:base, "A volunteer request is already open") if
      self.class.where(member_id: member_id, tool_id: tool_id, status: "open").exists?
  end
end
