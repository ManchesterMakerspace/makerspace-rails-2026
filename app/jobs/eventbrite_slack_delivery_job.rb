class EventbriteSlackDeliveryJob < ApplicationJob
  def perform(id)
    EventbriteIntegration::Lease.with("slack-delivery:#{id}") do |check|
      delivery = EventbriteSlackDelivery.find(id)
      return if delivery.failed_at || delivery.expired || delivery.due_at.nil? || delivery.due_at > Time.current
      return unless delivery.mode == Service::SlackConnector.message_destination_mode && EventbriteIntegration::Configuration.organization_allowed?(delivery.organization_id)
      if delivery.sending_at && delivery.ts.blank?
        delivery.set(failed_at: Time.current, last_error: 'AMBIGUOUS_SEND: reconcile Slack receipt before retrying')
        return
      end
      version = delivery.revision
      events = EventbriteEvent.where(organization_id: delivery.organization_id, :eventbrite_id.in => delivery.event_ids).to_a
      parent = EventbriteEvent.where(organization_id: delivery.organization_id, eventbrite_id: delivery.scope_id, series_parent: true).first
      if parent && !parent.announcement_public?
        events.each { |event| event.invalidated_at = parent.invalidated_at || Time.current }
      end
      if delivery.ts.blank?
        events = events.select(&:announcement_upcoming?)
        stale = delivery.kind == 'reminder' && delivery.day != Time.current.in_time_zone('America/New_York').to_date.iso8601
        if events.empty? || stale
          delivery.set(expired: true, due_at: nil)
          return
        end
      end
      return if events.empty?
      payload = EventbriteIntegration::AnnouncementMessage.build(delivery, events, series_url: parent&.announcement_public? ? parent.public_url : nil)
      if delivery.delivered_revision != version
        if delivery.ts.present?
          check.call
          Service::SlackConnector.client.chat_update(channel: delivery.channel, ts: delivery.ts, **payload, parse: 'none', link_names: false)
        else
          destination = Service::SlackConnector.resolved_channel_id(SystemConfig.get('slack_channel_upcoming_events').presence || 'upcoming-events')
          check.call
          delivery.set(sending_at: Time.current)
          begin
            response = Service::SlackConnector.client.chat_postMessage(channel: destination, **payload,
              client_msg_id: delivery.client_msg_id, parse: 'none', link_names: false, unfurl_links: false, unfurl_media: false)
            raise 'Missing Slack receipt' if response['ts'].blank? || response['channel'].blank?
            delivery.set(ts: response['ts'].to_s, channel: response['channel'], sending_at: nil)
            Service::SlackMessageLog.record(channel: destination, message: payload[:blocks], source: self.class.name, response: response)
          rescue Slack::Web::Api::Errors::SlackError, Slack::Web::Api::Errors::TooManyRequestsError => error
            # A provider server failure may have happened after accepting a post.
            rejected = error.respond_to?(:retry_after) || %w[channel_not_found not_in_channel is_archived invalid_auth token_revoked missing_scope invalid_blocks invalid_blocks_format invalid_arguments invalid_arg_name msg_too_long no_permission].include?(error.message.to_s)
            delivery.set(sending_at: nil) if rejected
            Service::SlackMessageLog.record(channel: destination, message: payload[:blocks], source: self.class.name, error: error)
            raise
          end
        end
        check.call
        delivery.set(delivered_revision: version, attempts: 0, last_error: nil)
      end
      # A crash here is repaired without reposting or repeating the successful edit.
      (events + [parent]).compact.each do |event|
        EventbriteEvent.collection.find(_id: event.id).update_one('$set' => {
          "slack_receipts.#{delivery.id}" => { 'ts' => delivery.ts, 'channel' => delivery.channel,
            'kind' => delivery.kind, 'day' => delivery.day, 'mode' => delivery.mode }
        })
      end
      EventbriteSlackDelivery.where(id: delivery.id, revision: version).update_all(due_at: nil)
    rescue EventbriteIntegration::Client::Deferred => error
      delivery&.set(due_at: Time.current + error.delay)
    rescue StandardError => error
      raise unless delivery
      rate_limited = error.respond_to?(:retry_after)
      attempts = delivery.attempts + (rate_limited ? 0 : 1)
      ambiguous = delivery.sending_at.present? && delivery.ts.blank?
      transient = error.message.to_s.match?(/internal_error|fatal_error|request_timeout|service_unavailable/)
      permanent = error.is_a?(Slack::Web::Api::Errors::SlackError) && !rate_limited && !transient
      detail = Service::SlackConnector.filter_log_data(
        'error' => Service::SlackConnector.format_api_error(error)
      ).fetch('error').first(4000)
      detail = "AMBIGUOUS_SEND: #{detail}" if ambiguous
      delivery.set(attempts: attempts, last_error: detail,
        failed_at: ambiguous || permanent || attempts >= 8 ? Time.current : nil,
        due_at: Time.current + (rate_limited ? [error.retry_after.to_f, 1].max : [2**attempts, 600].min))
      Rails.logger.error("Eventbrite Slack delivery #{id}: #{detail}")
    end
  rescue EventbriteIntegration::Client::Deferred
    # Another worker owns the delivery; the durable due marker remains.
  end
end
