class ToolAvailabilityService
  class << self
    def enqueue_reservation_canvas_refreshes(tool)
      return if tool.shop_id.blank?

      today = Time.current.in_time_zone(ReservationService::ZONE).to_date
      dates = [today, today + 1.day]
      window_start = beginning_of_day(dates.first)
      window_end = beginning_of_day(dates.last + 1.day)
      reservations = Reservation.blocking.where(
        shop_id: tool.shop_id,
        :tool_ids.in => [tool.id.to_s],
        :start_at.lt => window_end,
        :end_at.gt => window_start
      ).to_a

      affected_dates = dates.select do |date|
        day_start = beginning_of_day(date)
        day_end = beginning_of_day(date + 1.day)
        reservations.any? do |reservation|
          reservation.start_at < day_end && reservation.end_at > day_start
        end
      end
      return if affected_dates.empty?

      ReservationSlackCanvasSyncJob.perform_later(
        tool.shop_id.to_s,
        affected_dates.map(&:iso8601)
      )
    end

    private

    def beginning_of_day(date)
      ReservationService::ZONE.local(date.year, date.month, date.day).utc
    end
  end
end
