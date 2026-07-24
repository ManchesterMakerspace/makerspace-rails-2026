module Service
  module ReservationSlackCanvas
    LOCK_TTL_SECONDS = 60

    class << self
      def sync!(shop, dates:)
        return if shop.slack_channel.blank?

        channel_id = Service::SlackConnector.find_channel_id(shop.slack_channel)
        return if channel_id.blank?

        today = Time.current.in_time_zone(ReservationService::ZONE).to_date
        tomorrow = today + 1.day
        requested_dates = Array(dates).filter_map { |value| parse_date(value) }.uniq

        requested_dates.each do |date|
          configuration = canvas_configuration(date, today, tomorrow)
          next unless configuration

          field, title = configuration
          with_canvas_lock(shop.id, field) do
            shop.reload
            canvas_id = shop.public_send(field).presence
            reused_canvas = canvas_id.present?
            if canvas_id.blank?
              canvas_id = create_and_cache_canvas!(shop, field, title)
            end

            begin
              publish_agenda!(canvas_id, channel_id, shop, date)
            rescue Slack::Web::Api::Errors::CanvasNotFound,
                   Slack::Web::Api::Errors::CanvasDeleted
              raise unless reused_canvas

              shop.set(field => nil)
              canvas_id = create_and_cache_canvas!(shop, field, title)
              publish_agenda!(canvas_id, channel_id, shop, date)
            end
          end
        end
      end

      private

      def canvas_configuration(date, today, tomorrow)
        return [:canvas_today, "Today's Reservations"] if date == today
        return [:canvas_tomorrow, "Tomorrow's Reservations"] if date == tomorrow

        nil
      end

      def parse_date(value)
        return value if value.is_a?(Date)

        Date.iso8601(value.to_s)
      rescue Date::Error
        nil
      end

      def create_and_cache_canvas!(shop, field, title)
        canvas_id = Service::SlackConnector.create_canvas(title)
        raise "Slack did not return a canvas ID for #{title}" if canvas_id.blank?

        shop.set(field => canvas_id)
        canvas_id
      end

      def publish_agenda!(canvas_id, channel_id, shop, date)
        Service::SlackConnector.set_canvas_channel_access(canvas_id, channel_id)
        Service::SlackConnector.replace_canvas(
          canvas_id,
          agenda_markdown(shop, date)
        )
      end

      def agenda_markdown(shop, date)
        day_start = ReservationService::ZONE.local(
          date.year,
          date.month,
          date.day
        ).utc
        next_date = date + 1.day
        day_end = ReservationService::ZONE.local(
          next_date.year,
          next_date.month,
          next_date.day
        ).utc
        reservations = Reservation.blocking
          .where(
            shop_id: shop.id,
            :start_at.lt => day_end,
            :end_at.gt => day_start
          )
          .order_by(start_at: :asc)
          .to_a

        lines = [
          "# #{escape_markdown(shop.name)} Reservations",
          "## #{date.strftime('%A, %B %-d, %Y')}",
          ""
        ]

        if reservations.empty?
          lines << "_No pending or approved reservations._"
        else
          lines.concat([
            "| Time | Reservation | Member | Resources | Status |",
            "| --- | --- | --- | --- | --- |"
          ])
          reservations.each do |reservation|
            cells = [
              reservation_time(reservation),
              reservation_title(reservation),
              escape_table_cell(reservation.member&.fullname),
              escape_table_cell(resource_names(reservation)),
              escape_table_cell(reservation.status.to_s.titleize)
            ]
            lines << "| #{cells.join(' | ')} |"
          end
        end

        lines.concat([
          "",
          "_Last updated #{Time.current.in_time_zone(ReservationService::ZONE).strftime('%B %-d, %Y at %H:%M %Z')}._"
        ]).join("\n")
      end

      def reservation_time(reservation)
        start_at = reservation.start_at.in_time_zone(ReservationService::ZONE)
        end_at = reservation.end_at.in_time_zone(ReservationService::ZONE)
        if start_at.to_date == end_at.to_date
          "#{start_at.strftime('%H:%M')}-#{end_at.strftime('%H:%M')}"
        else
          "#{start_at.strftime('%b %-d %H:%M')}-#{end_at.strftime('%b %-d %H:%M')}"
        end
      end

      def reservation_title(reservation)
        title = escape_table_cell(reservation.title)
        return title if reservation.calendar_html_link.blank?

        "[#{title}](#{reservation.calendar_html_link})"
      end

      def resource_names(reservation)
        return "Entire shop" if reservation.reservation_scope == "shop"

        reservation.tools.map(&:name).join(", ")
      end

      def escape_markdown(value)
        value.to_s.gsub(/([\\`*_{}\[\]()#+.!-])/) { |match| "\\#{match}" }
      end

      def escape_table_cell(value)
        value.to_s.gsub(/\s+/, " ").gsub("|", "\\|").strip
      end

      def with_canvas_lock(shop_id, field)
        key = "reservation_canvas_lock/shop/#{shop_id}/#{field}"
        token = SecureRandom.uuid
        acquired = REDIS.set(key, token, nx: true, ex: LOCK_TTL_SECONDS)
        raise "Slack reservation canvas synchronization is busy" unless acquired

        yield
      ensure
        if key && token
          begin
            REDIS.eval(
              "if redis.call('get', KEYS[1]) == ARGV[1] then return redis.call('del', KEYS[1]) else return 0 end",
              keys: [key],
              argv: [token]
            )
          rescue Redis::BaseError => error
            Rails.logger.warn(
              "[ReservationSlackCanvasLockReleaseError] key=#{key} " \
              "error=#{error.class}: #{error.message}"
            )
          end
        end
      end
    end
  end
end
