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
  index({ organization_id: 1, listed: 1, invalidated_at: 1, starts_at: 1 })

  def self.signup_choices
    today = Time.current.in_time_zone('America/New_York').to_date
    zone = ActiveSupport::TimeZone['America/New_York']
    first = zone.local((today << 2).year, (today << 2).month, (today << 2).day)
    last = today >> 1
    finish = zone.local(last.year, last.month, last.day) + 1.day
    where(:organization_id.in => EventbriteIntegration::Configuration.organization_ids,
          listed: true, series_parent: false, invalidated_at: nil,
          :status.in => %w[live started ended completed], :starts_at.gte => first, :starts_at.lt => finish,
          :name.not => /open house/i).order_by(starts_at: :asc, eventbrite_id: :asc)
  end
end
