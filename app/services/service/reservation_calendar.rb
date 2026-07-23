module Service
  module ReservationCalendar
    class << self
      def sync!(reservation)
        calendar_id = Service::GoogleWorkspace.reservations_calendar_id
        raise "GOOGLE_RESERVATIONS_CALENDAR_ID is not configured" if calendar_id.blank?

        if reservation.denied? || reservation.cancelled?
          delete_event(calendar_id, reservation)
          reservation.set(
            calendar_sync_status: "deleted",
            calendar_sync_error: nil,
            calendar_synced_at: Time.current
          )
          return
        end

        event = build_event(reservation)
        result = upsert_event(calendar_id, event)
        reservation.set(
          calendar_event_id: result.id,
          calendar_sync_status: "synced",
          calendar_sync_error: nil,
          calendar_synced_at: Time.current
        )
      end

      private

      def upsert_event(calendar_id, event)
        service = Service::GoogleWorkspace.calendar
        begin
          service.get_event(calendar_id, event.id)
          service.update_event(calendar_id, event.id, event, send_updates: "all")
        rescue Google::Apis::ClientError => error
          raise unless error.status_code == 404
          service.insert_event(calendar_id, event, send_updates: "all")
        end
      end

      def delete_event(calendar_id, reservation)
        event_id = reservation.calendar_event_id.presence || reservation.id.to_s
        Service::GoogleWorkspace.calendar.delete_event(calendar_id, event_id, send_updates: "all")
      rescue Google::Apis::ClientError => error
        raise unless error.status_code == 404
      end

      def build_event(reservation)
        emails = if reservation.reservation_scope == "shop"
          [reservation.shop.resource_email]
        else
          reservation.tools.map(&:resource_email)
        end.compact.uniq

        Google::Apis::CalendarV3::Event.new(
          id: reservation.id.to_s,
          summary: "#{reservation.status == "pending" ? "[Pending] " : ""}#{reservation.title}",
          description: [
            "Member: #{reservation.member.fullname}",
            "Reservation: #{reservation.id}",
            "Status: #{reservation.status}",
            "Resources: #{resource_names(reservation)}"
          ].join("\n"),
          start: Google::Apis::CalendarV3::EventDateTime.new(
            date_time: reservation.start_at.to_datetime,
            time_zone: ReservationService::ZONE.tzinfo.name
          ),
          end: Google::Apis::CalendarV3::EventDateTime.new(
            date_time: reservation.end_at.to_datetime,
            time_zone: ReservationService::ZONE.tzinfo.name
          ),
          attendees: emails.map do |email|
            Google::Apis::CalendarV3::EventAttendee.new(email: email, resource: true)
          end
        )
      end

      def resource_names(reservation)
        return reservation.shop.name if reservation.reservation_scope == "shop"
        reservation.tools.map(&:name).join(", ")
      end
    end
  end
end
