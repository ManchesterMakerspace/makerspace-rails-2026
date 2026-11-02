class Reservation
  include Mongoid::Document
  include Mongoid::Timestamps
  include ActiveModel::Serializers::JSON

  STATUSES = %w[pending unpaid approved denied cancelled abandoned].freeze
  SCOPES = %w[shop tools].freeze
  ACTIVE_STATUSES = %w[pending unpaid approved].freeze
  SOURCES = %w[portal slack].freeze

  field :full_day, type: Boolean, default: false
  field :invoice, type: String
  field :previous_invoice_ids, type: Array, default: []
  field :fee_rule_snapshot, type: Array, default: []
  field :fee_snapshot, type: Array, default: []
  field :notified_at, type: String
  field :notified_channel_id, type: String

  def fee_invoice
    Invoice.where(id: invoice).first if invoice.present?
  end

  field :title, type: String
  field :reservation_scope, type: String
  field :tool_ids, type: Array, default: []
  field :selected_tool_ids, type: Array, default: []
  field :tool_group_ids, type: Array, default: []
  field :group_snapshots, type: Array, default: []

  def group_label
    group_snapshots.map { |group| "#{group['name']} (Group)" }.join(', ')
  end

  field :start_at, type: Time
  field :end_at, type: Time
  field :status, type: String, default: "approved"
  field :approval_reasons, type: Array, default: []
  field :approval_details, type: Array, default: []
  field :decision_note, type: String
  field :decided_at, type: Time
  field :source, type: String, default: "portal"
  field :reader_revision, type: Integer, default: 0
  field :reader_state_version, type: Integer, default: 0
  field :reader_scope_changed_at, type: Time
  field :arrived_at, type: Time
  field :arrival_reader_id, type: String
  field :arrival_tool_id, type: String
  field :arrival_checkin_id, type: String
  field :abandoned_at, type: Time
  field :abandonment_reason, type: String
  field :reader_monitor_started_at, type: Time
  field :reader_monitors, type: Hash, default: {}
  field :reader_receipts, type: Hash, default: {}
  field :reader_sync_pending, type: Boolean, default: false
  field :calendar_event_id, type: String
  field :calendar_html_link, type: String
  field :calendar_sync_status, type: String
  field :calendar_sync_error, type: String
  field :calendar_synced_at, type: Time
  field :scheduled_message_id, type: String
  field :scheduled_message_channel_id, type: String

  belongs_to :member
  belongs_to :shop
  belongs_to :decided_by, class_name: "Member", optional: true

  index({ invoice: 1 }, { sparse: true })
  index({ shop_id: 1, status: 1, start_at: 1, end_at: 1 })
  index({ member_id: 1, status: 1, start_at: 1, end_at: 1 })
  index({ tool_ids: 1, status: 1, start_at: 1, end_at: 1 })

  after_initialize :normalize_legacy_cancelled_status
  before_update :advance_reader_revision

  validates :title, presence: true
  validates :member, :shop, :start_at, :end_at, presence: true
  validates :reservation_scope, inclusion: { in: SCOPES }
  validates :status, inclusion: { in: STATUSES }
  validates :source, inclusion: { in: SOURCES }
  validate :valid_resource_selection
  validate :end_after_start

  scope :blocking, -> { where(:status.in => ACTIVE_STATUSES) }

  def tools
    Array(tool_ids).present? ? Tool.where(:id.in => Array(tool_ids)) : Tool.none
  end

  def blocking?
    ACTIVE_STATUSES.include?(status)
  end

  def cancelled?
    status == "cancelled"
  end

  alias_method :canceled?, :cancelled?

  def denied?
    status == "denied"
  end

  def abandoned? = status == "abandoned"

  def effective_approval_details
    details = Array(approval_details).map { |detail| detail.to_h.stringify_keys }
    return details if details.present?

    Array(approval_reasons).map do |reason|
      {
        "code" => reason,
        "message" => case reason
        when "overlapping_member_reservation"
          "This reservation overlaps another reservation you hold."
        when "resource_requires_approval"
          "The selected resource requires manager approval."
        when "blackout"
          "This reservation overlaps a shop blackout."
        else
          reason.to_s.humanize
        end
      }
    end
  end

  private

  def advance_reader_revision
    scope_fields = %w[start_at shop_id member_id reservation_scope tool_ids]
    return if (changes.keys & (scope_fields + %w[end_at status])).empty?
    self.reader_revision = reader_revision.to_i + 1
    if (changes.keys & scope_fields).any?
      self.reader_scope_changed_at = Time.current
      self.arrived_at = self.arrival_reader_id = self.arrival_tool_id = self.arrival_checkin_id = nil
      self.reader_monitor_started_at = nil
      self.reader_monitors = {}
    end
  end

  def normalize_legacy_cancelled_status
    self.status = "cancelled" if status == "canceled"
  end

  def valid_resource_selection
    ids = Array(tool_ids).map(&:to_s).uniq
    if reservation_scope == "shop"
      errors.add(:tool_ids, "must be empty for a shop reservation") if ids.present?
    elsif reservation_scope == "tools"
      errors.add(:tool_ids, "must select at least one tool") if ids.empty?
      valid_ids = Tool.where(shop_id: shop_id, :id.in => ids).pluck(:id).map(&:to_s)
      errors.add(:tool_ids, "must belong to the selected shop") unless (ids - valid_ids).empty?
    end
  end

  def end_after_start
    return if start_at.blank? || end_at.blank?
    errors.add(:end_at, "must be after start time") unless end_at > start_at
  end
end
