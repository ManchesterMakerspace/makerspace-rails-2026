# Called under the requester's renewable delivery lease. Slack is outside the
# database, so save the intended membership before sending and save Slack's
# receipt before copying it to the requests. Either write can then be retried.
class CheckoutReminderSender
  class << self
    def deliver!(post, check, now)
      return unless post.destination_mode == Service::SlackConnector.message_destination_mode
      unless post.ts
        prior = recover(post) if post.attempted_at
        if prior
          check.call
          post.set(posted_channel: prior.fetch('channel'), ts: prior.fetch('ts'))
        else
          requests = ToolCheckoutRequest.in(id: post.request_ids).where(member_id: post.member_id, status: 'open').includes(:member, :tool, :tool_group).select do |request|
            CheckoutRequestReminder.due?(request, now) && request.target.shop_id == post.shop_id &&
              CheckoutRequestReminder.request_day(request) == post.day && CheckoutRequestReminder.final_warning?(request) == post.final_warning
          end
          check.call
          return post.delete if requests.empty?
          send_waiting!(post, requests, now, check)
        end
      end

      check.call
      receipt = snapshot(post).merge('delivery_id' => post.id, 'status' => 'sent', 'ts' => post.ts,
        'channel' => post.posted_channel, 'sent_at' => post.attempted_at, 'finalized' => false,
        'destination_mode' => post.destination_mode, 'grouped' => post.request_ids.size > 1)
      ToolCheckoutRequest.collection.find('_id' => { '$in' => post.request_ids })
        .update_many('$set' => { "reminders.#{post.number}" => receipt, 'reminder_open' => true })
      post.delete
    end

    private

    def snapshot(post)
      { 'member_name' => post.member_name, 'shop_name' => post.shop_name, 'day' => post.day, 'declines_on' => post.declines_on }
    end

    def recover(post)
      channel = Service::SlackConnector.resolved_channel_id(post.channel)
      Service::SlackConnector.find_post_receipt(channel: channel, oldest: (post.attempted_at.to_i - 5).to_s, client_msg_id: post.id)
    end

    def send_waiting!(post, requests, now, check)
      first = requests.first
      deadline = (now.in_time_zone.to_date + CheckoutRequestReminder::INTERVAL_DAYS).iso8601 if post.final_warning
      post.set(request_ids: requests.map(&:id), number: CheckoutRequestReminder.due_number(first, now),
        member_name: first.member.fullname, shop_name: first.target.shop&.name, attempted_at: now, declines_on: deadline,
        channel: Service::SlackConnector.resource_managers_channel)
      text = if requests.one?
        CheckoutRequestReminder.waiting_message(first, declines_on: deadline)
      else
        CheckoutRequestReminder.group_message(requests, snapshot(post))
      end
      check.call
      begin
        response = Service::SlackConnector.send_slack_message(text, post.channel, client_msg_id: post.id)
        ts = response.respond_to?(:ts) ? response.ts : response&.fetch('ts', nil)
        channel = response.respond_to?(:channel) ? response.channel : response&.fetch('channel', nil)
        raise 'Slack returned no checkout reminder receipt' if ts.blank? || channel.blank?
      rescue => error
        # Keep intent (including UUID) for reconciliation after a timeout.
        check.call
        if error.respond_to?(:retry_after) || %w[channel_not_found not_in_channel invalid_auth missing_scope is_archived].include?(error.message)
          # Slack explicitly rejected the post. Retry with the current channel
          # setting so fixing a destination does not strand these requests.
          post.set(attempted_at: nil)
        end
        ToolCheckoutRequest.collection.find('_id' => { '$in' => post.request_ids })
          .update_many('$set' => { "reminders.#{post.number}" => { 'status' => 'failed', 'error_class' => error.class.name } })
        raise
      end
      check.call
      post.set(ts: ts, posted_channel: channel)
    end
  end
end
