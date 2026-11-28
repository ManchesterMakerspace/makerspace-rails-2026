module PublicEventbriteEventsHelper
  def eventbrite_start_label(start, timezone)
    zone = ActiveSupport::TimeZone[timezone.to_s] || ActiveSupport::TimeZone['America/New_York']
    local = start.in_time_zone(zone)
    clock = local.min.zero? ? '%-I%p' : '%-I:%M%p'
    local.strftime("%b #{local.day.ordinalize}, #{clock}")
  end
end
