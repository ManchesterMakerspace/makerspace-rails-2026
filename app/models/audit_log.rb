class AuditLog
  include Mongoid::Document
  include Mongoid::Timestamps

  store_in collection: 'audit_logs'

  # ── Discriminator ──────────────────────────────────────────────────────────
  # "member"  — changes to member records, invoices, rentals, etc.
  # "portal"  — changes to SystemConfig / portal settings
  # "slack"   — a Slack message the portal sent (Service::SlackMessageLog)
  field :log_type,      type: String

  # ── Event classification ───────────────────────────────────────────────────
  # Machine-readable action string. Examples:
  #   member_updated, membership_revoked, invoice_created, invoice_settled,
  #   rental_cancelled, rental_created, password_changed,
  #   portal_setting_changed
  # This list will grow as callsites are added.
  field :event_type,    type: String

  # ── Actor (who made the change) ────────────────────────────────────────────
  # Nil for system-initiated events (Lambda jobs, webhooks, IPN).
  field :actor_id,      type: BSON::ObjectId
  field :actor_name,    type: String   # denormalized at time of event

  # ── Subject (which member was affected) ────────────────────────────────────
  # Nil for portal-type logs where there is no member subject.
  # Same as actor when a member edits their own record.
  field :subject_id,    type: BSON::ObjectId
  field :subject_name,  type: String   # denormalized at time of event

  # ── Resource (which record was changed) ────────────────────────────────────
  field :resource_type, type: String   # Mongoid model class name: "Member", "Rental", "Invoice", etc.
  field :resource_id,   type: Object # ObjectId resources and integer repair-ticket IDs

  # ── Change data ────────────────────────────────────────────────────────────
  # field_changes:   diff of only changed fields — { "status" => ["activeMember", "revoked"] }
  #                  Named field_changes to avoid collision with Mongoid::Changeable#changes
  # before_snapshot: full document before change (sensitive fields scrubbed)
  # after_snapshot:  full document after change  (sensitive fields scrubbed)
  field :field_changes,    type: Hash
  field :before_snapshot,  type: Hash
  field :after_snapshot,   type: Hash

  # ── Slack ──────────────────────────────────────────────────────────────────
  field :slack_channel,  type: String   # nil if Slack post was not requested
  field :slack_message,  type: String   # always generated; only posted if slack_channel present
  field :slack_posted,   type: Boolean  # nil if not attempted; true/false after attempt

  # ── Request context ────────────────────────────────────────────────────────
  field :ip_address,    type: String   # from Current.ip_address; nil for system events

  # ── Indexes ────────────────────────────────────────────────────────────────
  index({ log_type:     1 })
  index({ event_type:   1 })
  index({ actor_id:     1 })
  index({ subject_id:   1 })
  index({ resource_type: 1, resource_id: 1 })
  index({ created_at:   1 })

  # ── Categories ─────────────────────────────────────────────────────────────
  # The audit log screen filters by category. A category is derived from the
  # event type (prefixes and exact names below), so every existing entry has
  # one without a data migration. An event type that matches none is "other",
  # so a new event type never drops out of view. Categories must not overlap,
  # so the database filter and category_for always agree (a spec checks this).
  CATEGORIES = {
    'email'        => { label: 'Email',                   exact: %w[system_email_sent], prefixes: [] },
    'slack'        => { label: 'Slack messages',          exact: [], prefixes: %w[slack_message_] },
    'settings'     => { label: 'Settings & system',       exact: %w[portal_setting_changed permissions_updated document_upload_failed google_api_permission_denied],
                        prefixes: %w[template_] },
    'members'      => { label: 'Members & accounts',      exact: %w[password_changed contract_signed blocked_login_attempt slack_email_mismatch fob_checkout_lookup],
                        prefixes: %w[member_ membership_ household_ totp_ card_ earned_membership_ slack_invite_ slack_identity_
                                     slack_promotion_ slack_manual_ slack_previous_ google_drive_] },
    'billing'      => { label: 'Billing',                 exact: %w[refund_requested],
                        prefixes: %w[invoice_ transaction_ subscription_ payment_method_ braintree_] },
    'rentals'      => { label: 'Rentals',                 exact: [], prefixes: %w[rental_] },
    'checkouts'    => { label: 'Checkouts, tools & shops', exact: [],
                        prefixes: %w[tool_ shop_ location_ checkout_] },
    'reservations' => { label: 'Reservations',            exact: [], prefixes: %w[reservation_ board_reservation_] },
    'fix_tickets'  => { label: 'Fix tickets',             exact: [], prefixes: %w[ticket_ fix_ticket_] },
    'volunteer'    => { label: 'Volunteer',               exact: [], prefixes: %w[volunteer_] },
  }.freeze
  OTHER_CATEGORY = 'other'.freeze
  ALL = 'all'.freeze
  # "All except Slack messages" -- the screen's default, so admin actions are
  # not buried under routine bot posts.
  ALL_EXCEPT_SLACK = 'all_except_slack'.freeze

  def self.category_for(event_type)
    name = event_type.to_s
    CATEGORIES.each do |key, rule|
      return key if rule[:exact].include?(name) || rule[:prefixes].any? { |prefix| name.start_with?(prefix) }
    end
    OTHER_CATEGORY
  end

  def self.category_condition(key)
    rule = CATEGORIES.fetch(key)
    patterns = rule[:prefixes].map { |prefix| /\A#{Regexp.escape(prefix)}/ }
    { 'event_type' => { '$in' => rule[:exact] + patterns } }
  end

  # Criteria for a category key; "all", nil or "" means every entry.
  def self.in_category(key)
    case key.to_s
    when '', ALL then all
    when ALL_EXCEPT_SLACK then where(:log_type.ne => Service::SlackMessageLog::LOG_TYPE)
    when OTHER_CATEGORY then where('$nor' => CATEGORIES.keys.map { |category| category_condition(category) })
    else
      raise ::Error::UnprocessableEntity.new("Unknown audit log category: #{key}") unless CATEGORIES.key?(key.to_s)
      where(category_condition(key.to_s))
    end
  end

  def category
    self.class.category_for(event_type)
  end

  # ── Validations ────────────────────────────────────────────────────────────
  validates :log_type,      presence: true
  validates :event_type,    presence: true
  validates :resource_type, presence: true
  validates :resource_id,   presence: true
  validates :slack_message, presence: true
end
