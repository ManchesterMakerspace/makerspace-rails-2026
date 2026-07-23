class ReservationCalendarSyncJob < ApplicationJob
  queue_as :default
  retry_on StandardError, wait: :polynomially_longer, attempts: 5

  def perform(reservation_id)
    reservation = Reservation.find(reservation_id)
    Service::ReservationCalendar.sync!(reservation)
  rescue Mongoid::Errors::DocumentNotFound
    nil
  rescue => error
    reservation&.set(
      calendar_sync_status: "failed",
      calendar_sync_error: error.message.to_s.first(500)
    )
    Honeybadger.notify(error) if defined?(Honeybadger)
    raise
  end
end
