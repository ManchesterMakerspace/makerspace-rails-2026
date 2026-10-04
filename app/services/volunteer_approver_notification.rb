require 'securerandom'

# A task submission has one review per claimant; an event has one attendance
# review. Persist each manager's receipt separately so retries do not notify
# managers whose DM has already succeeded.
class VolunteerApproverNotification
  DELIVERY_LEASE = 5.minutes

  class << self
    def notify!(record, now: Time.current)
      record.reload
      return unless ready?(record, now) && record.shop_id.present?

      Member.where(role: 'resource_manager', resource_manager_shop_ids: record.shop_id.to_s).each do |manager|
        next unless manager.manages_shop?(record.shop_id)
        next if manager.direct_notifications_suppressed?
        next if record.is_a?(VolunteerTask) && manager.id == record.claimed_by_id

        slack_user = SlackUser.find_by(member_id: manager.id)
        next unless slack_user&.slack_id.present?

        deliver!(record, manager, slack_user.slack_id, now)
      rescue => error
        Service::ErrorReporter.notify(error)
      end
    rescue => error
      Service::ErrorReporter.notify(error)
    end

    def ready?(record, now)
      if record.is_a?(VolunteerEvent)
        record.status == 'open' && record.event_date.present? && record.event_date < now.in_time_zone.to_date
      else
        record.status == 'pending' && record.completed_at.present?
      end
    end

    def review_url(record)
      parameter = record.is_a?(VolunteerEvent) ? 'event' : 'task'
      "#{ShortUrl.base_url}/volunteer?#{parameter}=#{record.id}"
    end

    private

    def submission_key(record)
      record.is_a?(VolunteerEvent) ? 'event' : "submission_#{(record.completed_at.to_f * 1000).round}"
    end

    def deliver!(record, manager, slack_id, now)
      claim_key = submission_key(record)
      path = "approver_notifications.#{claim_key}.#{manager.id}"
      token = SecureRandom.uuid
      selector = { '_id' => record.id, 'status' => record.status }
      selector['completed_at'] = native_time(record.completed_at) if record.is_a?(VolunteerTask)
      selector['event_date'] = Time.utc(record.event_date.year, record.event_date.month, record.event_date.day) if record.is_a?(VolunteerEvent)
      selector['$or'] = [
        { path => { '$exists' => false } },
        { "#{path}.state" => 'failed' },
        { "#{path}.state" => 'sending', "#{path}.attempted_at" => { '$lt' => native_time(now - DELIVERY_LEASE) } }
      ]

      acquired = record.class.collection.find(selector).find_one_and_update(
        { '$set' => { path => { 'state' => 'sending', 'token' => token, 'attempted_at' => native_time(now) } } },
        return_document: :after
      )
      return unless acquired

      posted = false
      begin
        # The record can be approved while the delivery lease is acquired.
        record.reload
        unless ready?(record, now) && submission_key(record) == claim_key &&
            record.shop_id.present? && manager.manages_shop?(record.shop_id) &&
            !manager.direct_notifications_suppressed? &&
            !(record.is_a?(VolunteerTask) && manager.id == record.claimed_by_id)
          finish!(record, path, token, { 'state' => 'obsolete' })
          return
        end

        response = Service::SlackConnector.send_slack_message(message(record), slack_id)
        ts = response && (response['ts'] || response[:ts])
        channel = response && (response['channel'] || response[:channel])
        raise 'Slack did not return an approver DM receipt' if ts.blank? || channel.blank?
        posted = true

        finish!(record, path, token, {
          'state' => 'sent', 'ts' => ts, 'channel' => channel, 'sent_at' => native_time(now),
          'destination_mode' => Service::SlackConnector.message_destination_mode
        })
      rescue => error
        # An accepted post whose receipt write failed is uncertain: retain the
        # sending lease and report it, rather than immediately reposting it.
        finish!(record, path, token, { 'state' => 'failed' }) unless posted
        raise error
      end
    end

    def finish!(record, path, token, attributes)
      saved = record.class.collection.find('_id' => record.id, "#{path}.token" => token).find_one_and_update(
        { '$set' => attributes.transform_keys { |name| "#{path}.#{name}" } }, return_document: :after
      )
      raise 'Volunteer approver DM receipt could not be saved; delivery may have succeeded' unless saved
    end

    def message(record)
      subject = if record.is_a?(VolunteerEvent)
        "Event *#{escape(record.title)}* (#{record.display_number}) is ready for attendance review " \
          "with #{record.attendee_count} checked-in attendee#{'s' unless record.attendee_count == 1}. " \
          'Review attendance and close the event to issue credits.'
      else
        claimant = record.claimed_by&.fullname || 'Unknown member'
        "*#{escape(claimant)}* submitted completion of *#{escape(record.title)}* (#{record.display_number}). " \
          'Please review this volunteer credit claim when you can.'
      end
      "#{subject}\n<#{review_url(record)}|Review #{record.is_a?(VolunteerEvent) ? 'event attendance' : 'claim'}>"
    end

    def escape(value)
      value.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
    end

    def native_time(value)
      Time.at(value.to_r).utc
    end
  end
end
