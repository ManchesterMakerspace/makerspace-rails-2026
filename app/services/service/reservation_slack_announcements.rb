require 'digest'

module Service
  module ReservationSlackAnnouncements
    class DeliveryError < StandardError; end
    class AmbiguousSend < DeliveryError; end

    OPENING_HOUR = 7
    MAX_SHOPS = 8
    MAX_ROWS = 40
    DEFINITE_REJECTIONS = %w[channel_not_found not_in_channel is_archived invalid_auth token_revoked
      missing_scope invalid_blocks invalid_blocks_format invalid_arguments invalid_arg_name msg_too_long
      no_permission restricted_action].freeze

    class << self
      def sync!(date: nil)
        today = Time.current.in_time_zone(ReservationService::ZONE).to_date
        date = date.present? ? Date.iso8601(date.to_s) : today
        return :skipped unless due?(date)

        reconcile_started_unpaid!(date)
        mode = Service::SlackConnector.message_destination_mode
        snapshot = Snapshot.new(date, mode)
        channels = (snapshot.channels.keys + ReservationSlackAnnouncement.where(day: date.iso8601, mode: mode).pluck(:channel_id)).uniq
        errors = snapshot.errors.dup
        channels.sort.each do |channel_id|
          begin
            errors.concat(Array(sync_channel!(date, mode, channel_id)))
          rescue ReservationAnnouncementLease::Busy
            # The owner (or the next scheduled reconciliation) delivers current state.
          rescue => error
            errors << error
            Rails.logger.error("[ReservationSlackAnnouncement] channel=#{channel_id} error=#{Service::SlackConnector.format_api_error(error)}")
          end
        end
        raise DeliveryError, errors.map { |error| Service::SlackConnector.format_api_error(error) }.uniq.join('; ') if errors.any?

        :synced
      end

      private

      def due?(date)
        now = Time.current.in_time_zone(ReservationService::ZONE)
        date == now.to_date && now.hour >= OPENING_HOUR
      end

      def reconcile_started_unpaid!(date)
        start_at, = day_bounds(date)
        Reservation.where(status: 'unpaid', :start_at.lte => Time.current, :end_at.gt => start_at).each do |reservation|
          ReservationFeeService.reconcile!(reservation) if reservation.invoice.present?
        end
      end

      def day_bounds(date)
        following = date + 1.day
        [ReservationService::ZONE.local(date.year, date.month, date.day),
         ReservationService::ZONE.local(following.year, following.month, following.day)]
      end

      def sync_channel!(date, mode, channel_id)
        ReservationAnnouncementLease.with("#{date.iso8601}/#{mode}/#{channel_id}") do |check|
          return unless due?(date) && mode == Service::SlackConnector.message_destination_mode
          key = { day: date.iso8601, mode: mode, channel_id: channel_id }
          receipt = ReservationSlackAnnouncement.where(key).first
          if receipt&.sending_at.present?
            raise AmbiguousSend, "AMBIGUOUS_SEND: reconcile reservation announcement #{receipt.id} before retrying"
          end
          return [DeliveryError.new("Reservation announcement #{receipt.id} deferred until #{receipt.retry_at.iso8601}")] if receipt&.retry_at && receipt.retry_at > Time.current

          # Reload under the lease: an older queued job must not overwrite a newer summary.
          snapshot = Snapshot.new(date, mode)
          data = snapshot.data(channel_id)
          if snapshot.routing_incomplete_for?(channel_id, receipt)
            raise DeliveryError, 'Channel resolution incomplete; preserving existing reservation announcement'
          end
          return if receipt&.ts.blank? && data[:starting].empty? && data[:promotions].empty?
          shop_ids = data[:shop_ids].presence || Array(receipt&.shop_ids)
          shops = shop_ids.filter_map { |id| snapshot.shops[id.to_s] }.sort_by { |shop| [shop.name.to_s.downcase, shop.id.to_s] }
          return if shops.empty?

          receipt ||= ReservationSlackAnnouncement.create!(key)
          # Canvas IDs are part of the payload, but publishing a canvas is unnecessary
          # when both the message and its known IDs are unchanged.
          current_canvas_ids = shops.first(MAX_SHOPS).to_h do |shop|
            [shop.id.to_s, mode == 'production' ? shop.canvas_today : shop.announcement_test_canvas_today]
          end
          payload = message(date, data, shops, current_canvas_ids, snapshot)
          fingerprint = digest(payload)
          return snapshot.errors if receipt.ts.present? && receipt.fingerprint == fingerprint

          canvas_ids = {}
          shops.first(MAX_SHOPS).each do |shop|
            check.call
            canvas_id = Service::ReservationSlackCanvas.ensure_today_for_announcement!(
              shop, channel_id: channel_id, date: date, mode: mode
            )
            raise DeliveryError, "Today's reservation canvas unavailable for shop #{shop.id}" if canvas_id.blank?
            raise DeliveryError, "Slack canvas URL unavailable for shop #{shop.id}" if Service::SlackConnector.slack_canvas_url(canvas_id).blank?
            canvas_ids[shop.id.to_s] = canvas_id
          end
          # Canvas I/O can take time. Recheck availability immediately before
          # rendering so a tool taken out of service loses its invitation.
          snapshot = Snapshot.new(date, mode)
          data = snapshot.data(channel_id)
          if snapshot.routing_incomplete_for?(channel_id, receipt, shop_ids: shops.map { |shop| shop.id.to_s })
            raise DeliveryError, 'Channel resolution incomplete after canvas refresh'
          end
          return if receipt.ts.blank? && data[:starting].empty? && data[:promotions].empty?
          fresh_shop_ids = data[:shop_ids].presence || Array(receipt.shop_ids)
          shops = fresh_shop_ids.filter_map { |id| snapshot.shops[id.to_s] }.sort_by { |shop| [shop.name.to_s.downcase, shop.id.to_s] }
          return if shops.empty?
          unless shops.first(MAX_SHOPS).all? { |shop| canvas_ids[shop.id.to_s].present? }
            raise DeliveryError, 'Reservation destinations changed during canvas refresh; retrying current state'
          end
          payload = message(date, data, shops, canvas_ids, snapshot)
          check.call
          return unless due?(date) && mode == Service::SlackConnector.message_destination_mode

          deliver!(receipt, payload, check)
          check.call
          receipt.set(fingerprint: digest(payload), shop_ids: shops.map { |shop| shop.id.to_s },
            canvas_ids: canvas_ids, empty_agenda: data[:starting].empty?, attempts: 0, retry_at: nil, last_error: nil)
          snapshot.errors
        rescue ReservationAnnouncementLease::Busy
          receipt&.set(fingerprint: nil)
          raise
        rescue => error
          record_failure(receipt, error) if receipt&.persisted?
          raise
        end
      end

      def deliver!(receipt, payload, check)
        if receipt.ts.present?
          begin
            response = Service::SlackConnector.client.chat_update(channel: receipt.channel_id, ts: receipt.ts,
              **payload, parse: 'none', link_names: false)
            Service::SlackConnector.record_slack_message(channel: receipt.channel_id, message: payload[:blocks],
              source: name, response: response)
            return
          rescue Slack::Web::Api::Errors::SlackError => error
            raise unless error.message.to_s == 'message_not_found'
            receipt.set(ts: nil, fingerprint: nil, client_msg_id: SecureRandom.uuid)
          end
        end

        check.call
        delete_previous_empty!(receipt, check)
        check.call
        raise DeliveryError, 'Reservation announcement day or destination mode changed before posting' unless due?(Date.iso8601(receipt.day)) && receipt.mode == Service::SlackConnector.message_destination_mode
        receipt.set(sending_at: Time.current)
        begin
          response = Service::SlackConnector.client.chat_postMessage(channel: receipt.channel_id, **payload,
            client_msg_id: receipt.client_msg_id, parse: 'none', link_names: false, unfurl_links: false, unfurl_media: false)
          raise AmbiguousSend, 'Slack did not return the reservation message receipt' if response['ts'].blank? || response['channel'].blank?
          raise AmbiguousSend, 'Slack returned a different reservation destination' unless response['channel'].to_s == receipt.channel_id
          receipt.set(ts: response['ts'].to_s, sending_at: nil)
          Service::SlackConnector.record_slack_message(channel: receipt.channel_id, message: payload[:blocks],
            source: name, response: response)
        rescue => error
          rejected = error.respond_to?(:retry_after) || DEFINITE_REJECTIONS.include?(error.message.to_s)
          receipt.set(sending_at: nil) if rejected
          Service::SlackConnector.record_slack_message(channel: receipt.channel_id, message: payload[:blocks],
            source: name, error: error)
          raise
        end
      end

      def delete_previous_empty!(receipt, check)
        yesterday = (Date.iso8601(receipt.day) - 1.day).iso8601
        previous = ReservationSlackAnnouncement.where(day: yesterday, mode: receipt.mode,
          channel_id: receipt.channel_id, empty_agenda: true, deleted_at: nil).first
        return if previous&.ts.blank?

        check.call
        begin
          Service::SlackConnector.client.chat_delete(channel: previous.channel_id, ts: previous.ts)
        rescue Slack::Web::Api::Errors::SlackError => error
          raise unless error.message.to_s == 'message_not_found'
        end
        previous.set(deleted_at: Time.current)
      rescue ReservationAnnouncementLease::Busy
        raise
      rescue => error
        # Removing an obsolete invitation is best effort; today's agenda still
        # needs to be announced when Slack cannot delete yesterday's message.
        Rails.logger.warn("[ReservationSlackAnnouncementCleanup] receipt=#{previous&.id} error=#{Service::SlackConnector.format_api_error(error)}")
      end

      def record_failure(receipt, error)
        attempts = receipt.attempts + 1
        detail = Service::SlackConnector.filter_log_data('error' => Service::SlackConnector.format_api_error(error)).fetch('error').to_s.first(2000)
        detail = "AMBIGUOUS_SEND: #{detail}" if receipt.sending_at.present?
        wait = error.respond_to?(:retry_after) ? [error.retry_after.to_f, 1].max : [2**[attempts, 10].min, 600].min
        receipt.set(attempts: attempts, retry_at: Time.current + wait, last_error: detail)
      end

      def digest(payload)
        Digest::SHA256.hexdigest(JSON.generate(payload))
      end

      def message(date, data, shops, canvas_ids, snapshot)
        date_text = date.strftime('%A, %B %-d, %Y')
        heading = "Reservations for #{date_text} (Eastern)"
        blocks = [{ type: 'header', text: { type: 'plain_text', text: heading } }]
        fallback = [heading]
        remaining = MAX_ROWS
        shown = 0
        shops.first(MAX_SHOPS).each do |shop|
          id = shop.id.to_s
          rows = data[:starting].select { |reservation| reservation.shop_id.to_s == id }
          selected = rows.first(remaining)
          remaining -= selected.length
          shown += selected.length
          promotions = data[:promotions].select { |promotion| promotion[:shop_id] == id }.sort_by { |promotion| promotion[:text] }
          link = canvas_ids[id].present? ? Service::SlackConnector.slack_canvas_url(canvas_ids[id]) : nil
          # Before canvas preparation this placeholder is used only for fingerprint comparison.
          link ||= "canvas-pending:#{id}"
          label = "*#{escape(shop.name.to_s.first(150))}*\n<#{link}|Live today agenda>"
          if promotions.any?
            label += "\n#{promotions.map { |promotion| escape(promotion[:text]) }.join("\n")}"
          elsif rows.empty?
            label += "\nNo reservations to announce for #{date_text}."
          end
          omitted = rows.length - selected.length
          label += "\n#{omitted} more reservation(s) in the agenda." if omitted.positive?
          blocks << { type: 'section', text: { type: 'mrkdwn', text: label.first(2900) },
            accessory: { type: 'button', text: { type: 'plain_text', text: "Reserve #{shop.name}".first(75) },
              action_id: 'reservation_open', value: id } }
          fallback << "#{shop.name}: #{link}"
          promotions.each { |promotion| fallback << promotion[:text] }
          selected.each do |reservation|
            text = reservation_line(reservation, snapshot)
            blocks << { type: 'section', text: { type: 'mrkdwn', text: text } }
            fallback << text
          end
        end
        omitted_rows = data[:starting].length - shown
        omitted_shops = [shops.length - MAX_SHOPS, 0].max
        footer = 'Times are Eastern. Canvas links open live rolling agendas.'
        if omitted_rows.positive? || omitted_shops.positive?
          footer += " #{omitted_rows} reservation(s) and #{omitted_shops} shop(s) omitted; see the full Member Portal reservations."
          portal_url = Service::ReservationSlackReminder.send(:portal_reservations_url)
          footer += " <#{portal_url}|All reservations>"
        end
        blocks << { type: 'context', elements: [{ type: 'mrkdwn', text: footer }] }
        { text: fallback.join("\n").first(39000), blocks: blocks }
      end

      def reservation_line(reservation, snapshot)
        start_at = reservation.start_at.in_time_zone(ReservationService::ZONE)
        end_at = reservation.end_at.in_time_zone(ReservationService::ZONE)
        finish = end_at.to_date == start_at.to_date ? end_at.strftime('%H:%M') : end_at.strftime('%b %-d %H:%M')
        time = reservation.full_day ? "Full day: #{start_at.strftime('%b %-d')} – #{end_at.strftime('%b %-d')} (exclusive end)" : "#{start_at.strftime('%H:%M')}–#{finish}"
        resources = reservation.reservation_scope == 'shop' ? 'Entire shop' :
          Array(reservation.tool_ids).map { |id| snapshot.tools[id.to_s]&.name || 'Unavailable tool' }.join(', ')
        resources = "#{reservation.group_label} — #{resources}" if reservation.group_snapshots.present?
        member = snapshot.members[reservation.member_id.to_s]&.fullname.to_s.presence || 'Member'
        "*#{escape(reservation.title.to_s.first(180))}* · #{escape(reservation.status.titleize)}\n#{time} · #{escape(resources.first(650))} · #{escape(member.first(120))}".first(2900)
      end

      def escape(text)
        text.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;').gsub(/[\r\n]+/, ' ')
      end
    end

    # One batched view of today's bookings and their resource routing. Channel
    # emptiness includes carryovers even though the announcement lists starts today.
    class Snapshot
      attr_reader :channels, :errors, :shops, :tools, :members

      def initialize(date, mode)
        @date, @mode = date, mode
        @start_at, @end_at = ReservationSlackAnnouncements.send(:day_bounds, date)
        @shops = Shop.all.to_a.index_by { |shop| shop.id.to_s }
        @tools = Tool.all.to_a.index_by { |tool| tool.id.to_s }
        @tools_by_shop = @tools.values.group_by { |tool| tool.shop_id.to_s }
        @reservations = Reservation.blocking.where(:start_at.lt => @end_at, :end_at.gt => @start_at)
          .order_by(start_at: :asc, id: :asc).to_a
        @reservations_by_shop = @reservations.group_by { |reservation| reservation.shop_id.to_s }
        @members = Member.where(:id.in => @reservations.map(&:member_id).uniq).to_a.index_by { |member| member.id.to_s }
        @blackouts = ReservationBlackout.all.to_a.group_by { |blackout| blackout.shop_id.to_s }
        @channels, @errors, @resolved, @unresolved_shop_ids = {}, [], {}, []
        @unresolved_reservation_ids = {}
        route_reservations
        route_promotions
      end

      def data(channel_id)
        result = @channels[channel_id] || blank_data
        result.merge(promotions: result[:busy] ? [] : result[:promotions],
          shop_ids: (result[:starting].map { |reservation| reservation.shop_id.to_s } +
            (result[:busy] ? [] : result[:promotions].map { |promotion| promotion[:shop_id] })).uniq)
      end

      def routing_incomplete_for?(channel_id, receipt, shop_ids: [])
        result = @channels[channel_id] || blank_data
        ids = shop_ids + Array(receipt&.shop_ids) + result[:starting].map { |reservation| reservation.shop_id.to_s } +
          result[:promotions].map { |promotion| promotion[:shop_id] }
        affected = ids & @unresolved_shop_ids
        return false if affected.empty?

        # A whole-shop booking may have one broken fanout destination while
        # still being fully represented in this channel. Deliver those known
        # rows, but never drop another booking hidden by a failed alias lookup.
        unresolved = affected.flat_map { |id| Array(@unresolved_reservation_ids[id]) }
        represented = result[:starting].map { |reservation| reservation.id.to_s }
        return false if represented.any? && (unresolved - represented).empty?
        return false if result[:promotions].any? && affected.all? { |id| Array(@reservations_by_shop[id]).empty? }

        true
      end

      private

      def blank_data
        { starting: [], busy: false, promotions: [] }
      end

      def channel(value, shop_id:)
        return if value.blank?
        normalized = Service::SlackChannelCache.normalize_name(value)
        if @resolved.key?(normalized)
          @unresolved_shop_ids << shop_id if @resolved[normalized].nil?
          return @resolved[normalized]
        end
        resolved = Service::SlackConnector.resolved_channel_id(normalized)
        unless Service::SlackChannelCache.channel_id?(resolved)
          raise DeliveryError, "Reservation announcement channel could not be resolved: #{normalized}"
        end
        @resolved[normalized] = resolved
      rescue => error
        @errors << error
        @unresolved_shop_ids << shop_id
        @resolved[normalized] = nil
      end

      def resource_channels(reservation, shop)
        names = if reservation.reservation_scope == 'shop'
          [shop.slack_channel] + Array(@tools_by_shop[shop.id.to_s]).map(&:users_channel)
        else
          Array(reservation.tool_ids).map { |id| @tools[id.to_s]&.users_channel.presence || shop.slack_channel }
        end
        names = names.compact_blank.uniq
        destinations = names.filter_map { |name| channel(name, shop_id: shop.id.to_s) }.uniq
        if names.any? { |name| @resolved[Service::SlackChannelCache.normalize_name(name)].nil? }
          (@unresolved_reservation_ids[shop.id.to_s] ||= []) << reservation.id.to_s
        end
        destinations
      end

      def route_reservations
        @reservations.each do |reservation|
          shop = @shops[reservation.shop_id.to_s]
          next unless shop
          resource_channels(reservation, shop).each do |channel_id|
            target = (@channels[channel_id] ||= blank_data)
            target[:busy] = true
            if reservation.start_at >= @start_at
              target[:starting] << reservation unless target[:starting].any? { |item| item.id == reservation.id }
            end
          end
        end
      end

      def route_promotions
        @shops.each_value do |shop|
          next unless shop.slack_announce_empty_reservations && !shop.disabled? && !shop.out_of_service?
          next if Array(@blackouts[shop.id.to_s]).any? { |blackout| blackout.occurrences_overlapping(@start_at, @end_at).any? }
          reservations = Array(@reservations_by_shop[shop.id.to_s])
          if shop.reservable && reservations.empty?
            promote(shop, shop.slack_channel, "Shop is wide open, book your time now!")
          end
          Array(@tools_by_shop[shop.id.to_s]).each do |tool|
            next unless tool.reservable && !tool.disabled? && !tool.out_of_service?
            next if reservations.any? { |reservation| reservation.reservation_scope == 'shop' || Array(reservation.tool_ids).map(&:to_s).include?(tool.id.to_s) }
            promote(shop, tool.users_channel.presence || shop.slack_channel,
              "#{tool.name.to_s.first(150)} is wide open, book your time now!")
          end
        end
      end

      def promote(shop, name, text)
        channel_id = channel(name, shop_id: shop.id.to_s)
        return unless channel_id
        target = (@channels[channel_id] ||= blank_data)
        target[:promotions] << { shop_id: shop.id.to_s, text: text } unless target[:promotions].any? { |item| item[:shop_id] == shop.id.to_s && item[:text] == text }
      end
    end
  end
end
