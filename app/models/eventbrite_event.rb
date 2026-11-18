class EventbriteEvent
  include EventbriteRecord
  store_in collection: 'eventbrite_events'
  field :name, type: String
  field :starts_at, type: Time
  field :ends_at, type: Time
  field :timezone, type: String
  field :listed, type: Boolean, default: false
  field :series_parent, type: Boolean, default: false
  field :status, type: String
  field :series_id, type: String
  field :public_url, type: String
  field :summary, type: String
  field :image_url, type: String
  field :venue_label, type: String
  field :restricted, type: Boolean, default: false
  field :capacity, type: Integer
  field :tickets_sold, type: Integer
  field :tickets_remaining, type: Integer
  field :ticket_sales_start_at, type: Time
  field :has_member_ticket_class, type: Boolean, default: false
  field :inventory_updated_at, type: Time
  field :inventory_refresh_at, type: Time
  field :slack_receipts, type: Hash, default: {}
  index({ organization_id: 1, series_id: 1 })
  index({ inventory_refresh_at: 1 })

  def announcement_public? = listed && !restricted && invalidated_at.nil? && %w[live started ended completed].include?(status)
  def announcement_upcoming? = announcement_public? && !series_parent && starts_at && starts_at > Time.current
  def announcement_scope = series_id.presence || eventbrite_id
  index({ organization_id: 1, listed: 1, invalidated_at: 1, starts_at: 1 })

  def self.signup_choices
    today = Time.current.in_time_zone('America/New_York').to_date
    zone = ActiveSupport::TimeZone['America/New_York']
    first = zone.local((today << 2).year, (today << 2).month, (today << 2).day)
    last = today >> 1
    finish = zone.local(last.year, last.month, last.day) + 1.day
    EventbriteIntegration::Configuration.scope_organizations(where(
          listed: true, series_parent: false, invalidated_at: nil,
          :status.in => %w[live started ended completed], :starts_at.gte => first, :starts_at.lt => finish,
          :name.not => /open house/i)).order_by(starts_at: :asc, eventbrite_id: :asc)
  end
end
