module Service
  module VolunteerApprovalReminder
    WAIT_DAYS = 5

    class << self
      # The receipt belongs to one submission. Keep its final delivery retryable
      # when an ordinary task is rejected and subsequently claimed again.
      def reset!(record, previous_notification:)
        previous = previous_notification.to_h
        return if previous.empty?

        5.times do
          record.reload
          current = record.approval_notification.to_h
          return if current.empty? || current['started_at'] != previous['started_at']
          return if previous['ts'].present? && current['ts'] != previous['ts']

          changed = record.class.collection.find(
            '_id' => record.id, 'approval_notification' => current
          ).find_one_and_update(
            { '$push' => { 'approval_notification_history' => current }, '$set' => { 'approval_notification' => {} } },
            return_document: :after
          )
          if changed
            record.reload
            return
          end
        end
        raise 'Volunteer reminder changed repeatedly while resetting a claim'
      end

      def outcome_attributes(record, outcome:, closed_at: Time.current)
        receipt = record.approval_notification.to_h
        started_at = native_time(receipt['started_at'] || waiting_since(record))
        return {} unless started_at

        { approval_notification: receipt.merge(
          'started_at' => started_at,
          'subject' => receipt['subject'] || subject(record),
          'outcome' => outcome,
          'closed_at' => native_time(closed_at),
          'finalized' => receipt['ts'].blank?
        ) }
      end

      # The domain transition has already succeeded. Add only final fields so
      # a Slack receipt registered concurrently cannot be erased by the review.
      def record_outcome!(record, snapshot, expected_status:)
        return if snapshot.empty?
        snapshot = normalize_receipt(snapshot)

        5.times do
          record.reload
          path, existing = notification_location(record, snapshot, match_timestamp: false)
          if !path && record.approval_notification.to_h.empty? && record.status == expected_status
            path, existing = 'approval_notification', {}
          end
          if path
            selector = {
              '_id' => record.id,
              "#{path}.started_at" => existing['started_at'],
              "#{path}.ts" => existing['ts']
            }
            selector['status'] = expected_status if path == 'approval_notification' && existing.empty?
            attributes = snapshot.slice('started_at', 'outcome', 'closed_at')
            attributes['subject'] = existing['subject'] || snapshot['subject']
            attributes['finalized'] = existing['ts'].blank?
            if write_notification(record, selector, path, attributes)
              record.reload
              return
            end
          else
            # A rejected standard task can be reclaimed before its final write.
            # Preserve that old review snapshot without touching the new claim.
            changed = record.class.collection.find(
              '_id' => record.id,
              'approval_notification_history' => {
                '$not' => { '$elemMatch' => { 'started_at' => snapshot['started_at'] } }
              }
            ).find_one_and_update(
              { '$push' => { 'approval_notification_history' => snapshot.merge('finalized' => snapshot['ts'].blank?) } },
              return_document: :after
            )
            if changed
              record.reload
              return
            end
          end
        end
        raise 'Volunteer reminder changed repeatedly while recording a review outcome'
      rescue => error
        ErrorReporter.notify(error)
        raise
      end

      def remind!(record, now: Time.current)
        record.reload
        sync_closed!(record)
        record.reload
        return unless overdue?(record, now)

        receipt = prepare_intent!(record, now)
        return unless receipt && receipt['closed_at'].blank?
        text = pending_text(record, receipt, now)

        if receipt['ts'].present?
          ensure_destination_mode!(receipt)
          SlackConnector.update_slack_message(receipt.fetch('channel'), receipt['ts'], text, resolved_channel: true)
          # A reviewer may have closed the claim while chat.update was running.
          # Force its saved final text back onto this message after the age edit.
          reopen_final_delivery!(record, receipt)
        else
          response = SlackConnector.send_slack_message(text, SlackConnector.admin_channel)
          ts = response_value(response, 'ts')
          channel = response_value(response, 'channel')
          raise 'Slack did not return a volunteer reminder timestamp and channel' if ts.blank? || channel.blank?

          receipt = receipt.merge(
            'ts' => ts, 'channel' => channel,
            'destination_mode' => SlackConnector.message_destination_mode
          )
          register_receipt!(record, receipt)
        end
        record.reload
        sync_closed!(record)
      rescue => error
        ErrorReporter.notify(error)
      end

      # A Slack failure never reverses an approval/denial. The saved outcome is
      # retried by the daily job, with its original closure time and channel.
      def sync_closed!(record)
        record.reload
        receipt = record.approval_notification.to_h
        if final_update_needed?(receipt)
          begin
            update_final(record, receipt)
            mark_finalized!(record, receipt)
          rescue => error
            ErrorReporter.notify(error)
          end
        end

        record.reload
        Array(record.approval_notification_history).each do |past_receipt|
          next unless final_update_needed?(past_receipt)

          begin
            update_final(record, past_receipt)
            mark_finalized!(record, past_receipt)
          rescue => error
            ErrorReporter.notify(error)
          end
        end
      rescue => error
        ErrorReporter.notify(error)
      end

      private

      # Intent exists before the network request. A simultaneous rejection can
      # archive it, allowing the returned ts to find that exact old submission.
      def prepare_intent!(record, now)
        5.times do
          record.reload
          return unless overdue?(record, now)

          receipt = record.approval_notification.to_h
          return receipt if receipt['started_at'].present?
          started_at = waiting_since(record)
          selector = waiting_selector(record, started_at).merge(
            '_id' => record.id, 'approval_notification.started_at' => nil,
            'approval_notification.ts' => receipt['ts']
          )
          attributes = { 'started_at' => started_at, 'subject' => subject(record), 'finalized' => true }
          if write_notification(record, selector, 'approval_notification', attributes)
            record.reload
            return record.approval_notification.to_h
          end
        end
        raise 'Volunteer claim changed repeatedly while preparing a reminder'
      end

      def overdue?(record, now)
        if record.is_a?(VolunteerEvent)
          record.status == 'open' && record.event_date.present? && record.event_date < now.to_date - WAIT_DAYS
        else
          record.status == 'pending' && record.completed_at.present? && record.completed_at < now - WAIT_DAYS.days
        end
      end

      def waiting_since(record)
        value = record.is_a?(VolunteerEvent) ? record.event_date&.in_time_zone&.beginning_of_day : record.completed_at
        native_time(value)
      end

      def subject(record)
        if record.is_a?(VolunteerEvent)
          "Event *#{escape(record.title)}* (#{record.display_number}), " \
            "scheduled for #{record.event_date.strftime('%m/%d/%Y')}, " \
            "with #{record.attendee_count} checked-in attendee#{'s' unless record.attendee_count == 1}"
        else
          claimant = record.claimed_by&.fullname || 'Unknown member'
          "Task *#{escape(record.title)}* (#{record.display_number}) for *#{escape(claimant)}*"
        end
      end

      def elapsed(record, receipt, finish)
        start = receipt.fetch('started_at')
        days = if record.is_a?(VolunteerEvent)
          (finish.in_time_zone.to_date - start.in_time_zone.to_date).to_i
        else
          ((finish - start) / 1.day).floor
        end
        days = [days, 0].max
        "#{days} day#{'s' unless days == 1}"
      end

      def pending_text(record, receipt, now)
        action = record.is_a?(VolunteerEvent) ? 'Review attendance and close the event to process credits.' : 'Review the submitted completion.'
        "⏰ #{subject(record)} has been waiting for volunteer approver review for " \
          "#{elapsed(record, receipt, now)}. #{action}"
      end

      def final_update_needed?(receipt)
        receipt['ts'].present? && receipt['closed_at'].present? && !receipt['finalized']
      end

      def update_final(record, receipt)
        ensure_destination_mode!(receipt)
        outcome = receipt.fetch('outcome')
        icon = if outcome.start_with?('Credit award failed')
          '⚠️'
        elsif outcome.start_with?('Denied')
          '❌'
        else
          '✅'
        end
        text = "#{icon} #{receipt.fetch('subject')}: #{escape(outcome)}. " \
          "Review closed after #{elapsed(record, receipt, receipt.fetch('closed_at'))}."
        SlackConnector.update_slack_message(receipt.fetch('channel'), receipt.fetch('ts'), text, resolved_channel: true)
      end

      # Persist only delivery fields: a concurrent review can add its outcome
      # without having that snapshot replaced by an older reminder worker.
      def register_receipt!(record, receipt)
        receipt = normalize_receipt(receipt)
        5.times do
          record.reload
          path, existing = notification_location(record, receipt, match_timestamp: false)
          unless path
            delete_duplicate!(receipt)
            return
          end

          if existing['ts'].present?
            delete_duplicate!(receipt) unless existing['ts'] == receipt['ts'] && existing['channel'] == receipt['channel']
            return
          end

          selector = {
            '_id' => record.id,
            "#{path}.started_at" => existing['started_at'],
            "#{path}.ts" => nil
          }
          if path == 'approval_notification' && existing['started_at'].nil?
            selector.merge!(waiting_selector(record, receipt['started_at']))
          end
          attributes = receipt.slice('ts', 'channel', 'started_at', 'destination_mode')
          attributes['subject'] = existing['subject'] || receipt['subject']
          attributes['finalized'] = existing['closed_at'].blank?
          return if write_notification(record, selector, path, attributes)
        end

        raise 'Volunteer reminder receipt changed repeatedly during registration'
      end

      def mark_finalized!(record, receipt)
        record.reload
        path, existing = notification_location(record, receipt)
        return unless path && existing['closed_at'] == receipt['closed_at'] && existing['outcome'] == receipt['outcome']

        selector = receipt_selector(record, path, existing).merge(
          "#{path}.closed_at" => receipt['closed_at'],
          "#{path}.outcome" => receipt['outcome']
        )
        write_notification(record, selector, path, 'finalized' => true)
        record.reload
      end

      def reopen_final_delivery!(record, receipt)
        record.reload
        path, existing = notification_location(record, receipt)
        return unless path && existing['closed_at'].present?

        write_notification(record, receipt_selector(record, path, existing), path, 'finalized' => false)
      end

      def notification_location(record, receipt, match_timestamp: true)
        current = record.approval_notification.to_h
        candidates = [['approval_notification', current]] +
          Array(record.approval_notification_history).each_with_index.map { |saved, index| ["approval_notification_history.#{index}", saved] }
        candidates.find do |path, saved|
          same_start = saved['started_at'] == receipt['started_at']
          if path == 'approval_notification' && saved['started_at'].nil?
            same_start = waiting?(record) && waiting_since(record) == receipt['started_at']
          end
          same_start && (!match_timestamp || saved['ts'] == receipt['ts'])
        end
      end

      def waiting?(record)
        record.status == (record.is_a?(VolunteerEvent) ? 'open' : 'pending')
      end

      def waiting_selector(record, started_at)
        if record.is_a?(VolunteerEvent)
          date = record.event_date
          { 'status' => 'open', 'event_date' => Time.utc(date.year, date.month, date.day) }
        else
          { 'status' => 'pending', 'completed_at' => native_time(started_at) }
        end
      end

      def receipt_selector(record, path, receipt)
        { '_id' => record.id, "#{path}.ts" => receipt['ts'], "#{path}.started_at" => receipt['started_at'] }
      end

      def write_notification(record, selector, path, attributes)
        fields = normalize_receipt(attributes).to_h { |key, value| ["#{path}.#{key}", value] }
        record.class.collection.find(selector).find_one_and_update(
          { '$set' => fields }, return_document: :after
        )
      end

      def delete_duplicate!(receipt)
        ensure_destination_mode!(receipt)
        SlackConnector.delete_slack_message(receipt.fetch('channel'), receipt.fetch('ts'), resolved_channel: true)
      end

      def ensure_destination_mode!(receipt)
        mode = receipt['destination_mode'] || SlackConnector.message_destination_mode
        raise 'Volunteer reminder destination does not belong to this Slack environment' unless mode == SlackConnector.message_destination_mode
      end

      # Raw BSON serialization does not preserve TimeWithZone's UTC instant.
      # Use native UTC Time values for every persisted review clock and query.
      def native_time(value)
        value&.to_time&.getutc
      end

      def normalize_receipt(receipt)
        receipt.to_h.transform_keys(&:to_s).to_h do |key, value|
          [key, %w[started_at closed_at].include?(key) ? native_time(value) : value]
        end
      end

      def response_value(response, key)
        return response.public_send(key) if response.respond_to?(key)
        return unless response.respond_to?(:[])

        response[key] || response[key.to_sym]
      end

      def escape(text)
        text.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
      end
    end
  end
end
