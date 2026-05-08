class VolunteerEvent
  include Mongoid::Document
  include Mongoid::Timestamps
  include Service::SlackConnector

  store_in collection: 'volunteer_events'

  field :event_number,  type: Integer
  field :title,         type: String
  field :description,   type: String
  field :credit_value,  type: Float,   default: 1.0
  field :event_date,    type: Date
  field :status,        type: String,  default: 'open'  # open | closed
  field :created_by_id, type: BSON::ObjectId
  field :closed_by_id,  type: BSON::ObjectId, default: nil
  field :closed_at,     type: Time,           default: nil
  field :attendee_ids,  type: Array,          default: []  # array of member BSON::ObjectId

  VALID_STATUSES = %w[open closed].freeze

  validates :title,        presence: true
  validates :credit_value, numericality: { greater_than: 0 }
  validates_inclusion_of :status, in: VALID_STATUSES

  before_create :assign_event_number

  index({ status: 1 })
  index({ event_number: 1 }, { unique: true })

  # ── Scopes ────────────────────────────────────────────────────────────────

  scope :active_events,   -> { where(status: 'open') }
  scope :closed_events, -> { where(status: 'closed') }

  # ── Class Methods ─────────────────────────────────────────────────────────

  def self.find_by_number(number)
    find_by(event_number: number.to_i)
  end

  # ── Instance Methods ──────────────────────────────────────────────────────

  def display_number
    "E#{event_number}"
  end

  def attendee_count
    attendee_ids.length
  end

  def created_by
    Member.find(created_by_id) if created_by_id
  end

  def closed_by
    Member.find(closed_by_id) if closed_by_id
  end

  # Add a member to the event — guard against duplicates
  def checkin!(member)
    raise Error::Forbidden.new unless status == 'open'
    raise Error::Forbidden.new if attendee_ids.include?(member.id)
    push(attendee_ids: member.id)
    notify_member_checkin(member)
  end

  # Admin manually adds an attendee
  def add_attendee!(member, added_by)
    raise Error::Forbidden.new unless status == 'open'
    raise Error::Forbidden.new if attendee_ids.include?(member.id)
    push(attendee_ids: member.id)
  end

  # Close the event and issue credits to all attendees
  def close!(closer)
    raise Error::Forbidden.new unless status == 'open'

    update!(
      status:      'closed',
      closed_by_id: closer.id,
      closed_at:   Time.now
    )

    # Issue credits to all attendees
    attendee_ids.each do |member_id|
      credit = VolunteerCredit.create!(
        member_id:    member_id,
        issued_by_id: closer.id,
        description:  "Attended event: #{title}",
        credit_value: credit_value,
        status:       'approved'
      )
      credit.send(:notify_member_credit_awarded)
      credit.send(:check_discount_threshold!)
    end
  end

  private

  def assign_event_number
    counter_key = 'volunteer_event_counter'
    current     = SystemConfig.get(counter_key).to_i
    next_number = current + 1
    SystemConfig.set(counter_key, next_number.to_s)
    self.event_number = next_number
  end

  def notify_member_checkin(member)
    slack_user = SlackUser.find_by(member_id: member.id)
    return unless slack_user

    enque_message(
      "✅ You're checked in to *#{title}* (#{display_number}). Credits will be issued when the event closes.",
      slack_user.slack_id
    )
  rescue => e
    Honeybadger.notify(e) if defined?(Honeybadger)
  end
end
