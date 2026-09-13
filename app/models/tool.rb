class Tool
  include Mongoid::Document
  include DurationFeeResource
  include ActiveModel::Serializers::JSON

  field :name, type: String
  field :wiki_url, type: String
  field :gdrive_id, type: String
  field :description, type: String
  # Sensitive/private info (e.g. lock combo) -- only surfaced to privileged
  # members, checkout approvers for this tool, and members with an active
  # checkout on it. See Tool#notes_visible_to? and ToolSerializer.
  field :notes, type: String
  field :open, type: Boolean, default: false
  field :disabled, type: Boolean, default: false
  # Independent of Hidden (disabled): unavailable tools remain in the catalog.
  field :out_of_service, type: Boolean, default: false
  field :allow_pending, type: Boolean, default: false
  field :announce, type: Boolean, default: false
  field :announce_channel, type: String
  field :users_channel, type: String
  # Optional prerequisite tool IDs — UI warns if member hasn't been checked out on these
  field :prerequisite_ids, type: Array, default: []
  field :reservable, type: Boolean, default: false
  field :max_concurrent_reservations, type: Integer, default: 1
  field :reservation_horizon_days, type: Integer, default: 7
  field :max_reservation_duration_hours, type: Float, default: 8.0
  field :reservation_requires_approval, type: Boolean, default: false
  field :reservation_prerequisite_tool_ids, type: Array, default: []
  field :google_resource_id, type: String
  field :resource_email, type: String

  belongs_to :shop

  before_validation :normalize_external_fields
  after_save :warm_changed_slack_channel_cache
  after_save :enqueue_checkout_canvas_sync_after_catalog_change
  after_destroy :enqueue_checkout_canvas_sync_after_destroy

  validates :name, presence: true
  # Scoped per shop, not global -- a common name like "Hand Tools" is allowed
  # to exist once per shop. Slack lookups that resolve a tool by name (see
  # SlackCheckoutRequestJob) are shop-scoped too, so this can't go ambiguous.
  validates :name, uniqueness: { case_sensitive: false, scope: :shop_id, message: 'already exists in this shop' }
  validates :shop, presence: true
  validates :max_concurrent_reservations, numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validates :reservation_horizon_days, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :max_reservation_duration_hours, numericality: { greater_than: 0 }
  validate :reservation_duration_uses_half_hours
  validate :reservation_prerequisites_belong_to_shop

  index({ shop_id: 1, name: 1 }, {
    unique: true,
    collation: { locale: 'en', strength: 2 },
    partial_filter_expression: { name: { '$type' => 'string' } }
  })

  index({ shop_id: 1, name: 1, _id: 1, disabled: 1 }, collation: { locale: "en", strength: 2 })

  def open
    read_attribute(:open) == true
  end

  def checkout_request_error(member)
    return "No checkout required" if open
    eligible = member.status == "pending" ? allow_pending : (member.status == "activeMember" && member.active_unexpired?)
    return "Your membership must first be activated and you must complete your Orientation checkout before requesting this Safety Checkout" unless eligible
    return "A checkout record already exists for this tool" if ToolCheckout.where(member_id: member.id, tool_id: id).exists?
    return "An open request already exists for this tool" if ToolCheckoutRequest.where(member_id: member.id, tool_id: id, status: "open").exists?
    nil
  end

  def disabled
    value = read_attribute(:disabled)
    value.nil? ? false : value
  end

  def reservable
    value = read_attribute(:reservable)
    value.nil? ? false : value
  end

  def effective_wiki_url
    wiki_url.to_s.strip.presence || WikiUrlBuilder.tool_url(shop&.name, name)
  end

  def allow_pending
    value = read_attribute(:allow_pending)
    value.nil? ? false : value
  end

  # Mirrors ApplicationController#can_approve_checkout_for_tool?, plus a
  # member with a currently active (non-revoked) checkout -- an open,
  # not-yet-approved request does not grant visibility (see #189).
  def notes_visible_to?(member)
    return false if member.nil?
    return true if member.role.in?(%w[admin board_member])
    return true if member.manages_shop?(shop_id)
    return true if CheckoutApprover.find_by(member_id: member.id)&.can_approve_tool?(self)

    ToolCheckout.where(member_id: member.id, tool_id: id, revoked_at: nil).exists?
  end

  def effective_reservation_prerequisite_ids
    (Array(reservation_prerequisite_tool_ids).map(&:to_s) + (open ? [] : [id.to_s])).reject(&:blank?).uniq
  end

  def reservation_prerequisites
    Tool.where(:id.in => effective_reservation_prerequisite_ids)
  end

  # Human-readable prerequisite names for display
  def prerequisites
    prerequisite_ids.present? ? Tool.where(:id.in => prerequisite_ids) : []
  end

  private

  CHECKOUT_CANVAS_FIELDS = %w[
    shop_id name description wiki_url prerequisite_ids disabled out_of_service
  ].freeze

  def enqueue_checkout_canvas_sync_after_catalog_change
    return unless previous_changes.keys.any? { |field| CHECKOUT_CANVAS_FIELDS.include?(field.to_s) }

    previous_shop_id = previous_changes["shop_id"]&.first
    enqueue_checkout_canvas_syncs([shop_id, previous_shop_id])
  end

  def enqueue_checkout_canvas_sync_after_destroy
    enqueue_checkout_canvas_syncs([shop_id])
  end

  def enqueue_checkout_canvas_syncs(shop_ids)
    Shop.where(:id.in => shop_ids.compact.uniq).each do |affected_shop|
      has_active_checkouts = affected_shop.id.to_s == shop_id.to_s &&
        ToolCheckout.where(tool_id: id, revoked_at: nil).exists?
      next if affected_shop.checkout_canvas_id.blank? && !has_active_checkouts

      ToolCheckoutSlackCanvasSyncJob.perform_later(affected_shop.id.to_s)
    end
  end

  def normalize_external_fields
    self.wiki_url = wiki_url.to_s.strip.presence
    self.gdrive_id = gdrive_id.to_s.strip.presence
    self.announce_channel =
      Service::SlackChannelCache.normalize_name(announce_channel).presence
    self.users_channel =
      Service::SlackChannelCache.normalize_name(users_channel).presence
  end

  def warm_changed_slack_channel_cache
    return if Rails.env.test?

    %w[announce_channel users_channel].each do |field|
      next unless previous_changes.key?(field)

      channel_name = public_send(field)
      Service::SlackChannelCache.lookup(
        channel_name,
        refresh_on_miss: true
      ) if channel_name.present?
    end
  end

  def reservation_duration_uses_half_hours
    value = max_reservation_duration_hours.to_f
    errors.add(:max_reservation_duration_hours, "must use half-hour increments") unless (value * 2).round == value * 2
  end

  def reservation_prerequisites_belong_to_shop
    ids = Array(reservation_prerequisite_tool_ids).map(&:to_s).uniq
    return if ids.empty? || shop_id.blank?

    valid_ids = Tool.where(shop_id: shop_id, :id.in => ids).pluck(:id).map(&:to_s)
    errors.add(:reservation_prerequisite_tool_ids, "must belong to this shop") unless (ids - valid_ids).empty?
  end
end
