# "Still waiting" reminders for open checkout requests. A request that has been
# open for 5 days gets a post in the configured Resource Managers channel
# (`slack_channel_rm`), and another every 5 days after that, up to 3 reminders.
# The third says it is the last reminder. If no checkout is recorded 5 days after
# the third reminder the system declines the request (see `time_out_due!`).
# Matching requests share one post. When a request closes, the post lists the
# remaining tools or reports that the last request has closed.
#
# Each reminder has a receipt on the request (`reminders`, keyed by reminder
# number). A short lease prevents concurrent workers posting the same reminder
# twice; failed or expired attempts are retried by the next scan. A reminder that
# was posted but whose resolution edit failed stays `reminder_open` and is
# retried by the daily job.
module CheckoutRequestReminder
  INTERVAL_DAYS = 5
  # Reminders actually posted, not elapsed intervals, so a request that is already
  # old when this ships still gets all of them before it is declined.
  MAX_REMINDERS = 3

  class << self
    # Calendar days in the application time zone, so the reminder and the
    # approver digest agree on how old a request is.
    def due_number(request, now)
      return 0 unless request.request_date

      ((now.in_time_zone.to_date - request.request_date.in_time_zone.to_date).to_i / INTERVAL_DAYS).floor
    end

    def deliver_due!(requests, now: Time.current)
      work = Hash.new { |hash, key| hash[key] = [] }
      requests.only(:id, :member_id, :request_date).each do |request|
        next unless request.request_date
        work[[request_day(request), request.member_id]] << request.id
      end
      # A crash can leave an accepted post to record even if every request closed.
      CheckoutReminderDelivery.all.only(:day, :member_id).each { |post| work[[post.day, post.member_id]] }
      work.sort_by { |(day, member), _| [day, member.to_s] }.each do |(day, member), ids|
        deliver_for!(day, member, ids, now) do |error, request_ids|
          Service::ErrorReporter.notify(error, context: { phase: 'checkout request reminder', request_ids: request_ids.map(&:to_s) })
        end
      rescue SlackDeliveryLease::Busy
        next
      rescue => error
        Service::ErrorReporter.notify(error, context: { phase: 'checkout request reminder', member_id: member.to_s })
      end
    end

    def remind!(request, now: Time.current)
      return unless request.request_date
      deliver_for!(request_day(request), request.member_id, [request.id], now)
    end

    def due?(request, now)
      number = due_number(request, now)
      receipt = request.reminders.fetch(number.to_s, {})
      request.open? && request.member && request.target && number.positive? &&
        sent_receipts(request).size < MAX_REMINDERS && receipt['status'] != 'sent' &&
        !(receipt['lease_until'] && receipt['lease_until'] >= now)
    end

    def request_day(request) = request.request_date.in_time_zone.to_date.iso8601
    def final_warning?(request) = sent_receipts(request).size == MAX_REMINDERS - 1

    def with_member_lease(id, &block)
      SlackDeliveryLease.with("checkout_reminder:#{ToolCheckoutRequest.collection.database.name}:#{id}", &block)
    end

    # Decline a request once all reminders have been posted and the last one has had
    # its full interval with no checkout recorded. Returns true when it declined.
    def time_out_due!(request, now: Time.current)
      request.reload
      return false unless request.open?

      sent = sent_receipts(request)
      return false if sent.size < MAX_REMINDERS

      last_sent = sent.map { |receipt| receipt['sent_at'] }.compact.max
      return false unless last_sent && last_sent.in_time_zone.to_date <= now.in_time_zone.to_date - INTERVAL_DAYS

      CheckoutRequestDecision.time_out!(request: request, now: now)
    end

    def sent_receipts(request)
      request.reminders.values.select { |receipt| receipt['status'] == 'sent' }
    end

    # Edit every posted reminder for a request that is no longer open.
    def finalize!(request, now: Time.current)
      request.reload
      return if request.open? || !request.reminder_open
      with_member_lease(request.member_id) { |check| finalize_receipts!(request.reload, now, check) }
    rescue SlackDeliveryLease::Busy
      # Another send or edit owns the member. The daily scan retries this flag.
      nil
    end

    def finalize_receipts!(request, now, check)
      request.reminders.each do |key, receipt|
        next unless receipt['status'] == 'sent' && !receipt['finalized'] && receipt['ts'].present?
        # A partially recorded send must finish copying receipts before an edit
        # can use them to determine the complete membership of its Slack post.
        next if receipt['delivery_id'] && CheckoutReminderDelivery.where(id: receipt['delivery_id']).exists?
        next if receipt['destination_mode'] && receipt['destination_mode'] != Service::SlackConnector.message_destination_mode
        resolved_ids = [request.id]
        text = if receipt['grouped']
          participants = ToolCheckoutRequest.where(member_id: request.member_id, "reminders.#{key}.delivery_id" => receipt.fetch('delivery_id'))
          pending, closed = participants.partition(&:open?)
          resolved_ids = closed.map(&:id)
          group_message(pending, receipt)
        else
          resolved_message(request)
        end
        check.call
        begin
          Service::SlackConnector.update_slack_message(receipt['channel'], receipt['ts'], text, resolved_channel: true)
          check.call
        rescue
          # An uncertain or late chat.update can land after another worker's
          # final edit. Make the latest state eligible for reconciliation again.
          ToolCheckoutRequest.collection.find('_id' => request.id, "reminders.#{key}.ts" => receipt['ts'])
            .update_one('$set' => { "reminders.#{key}.finalized" => false, 'reminder_open' => true })
          raise
        end
        # Only acknowledge closures observed in this edit's snapshot. Anything
        # that closed during chat.update still needs a fresh resolution edit.
        ToolCheckoutRequest.collection.find('_id' => { '$in' => resolved_ids })
          .update_many('$set' => { "reminders.#{key}.finalized" => true, "reminders.#{key}.finalized_at" => now })
      end
      request.reload
      unresolved = request.reminders.any? do |_, receipt|
        receipt['status'] == 'sent' && receipt['ts'].present? && !receipt['finalized']
      end
      request.set(reminder_open: false) unless unresolved
    end

    def waiting_message(request, declines_on: nil)
      text = "*#{CheckoutDisplay.escape(request.member.fullname)}* requested checkout on " \
             "*#{target_label(request)}* (#{CheckoutDisplay.escape(request.target.shop&.name)}) " \
             "on #{request_day(request)} and is still waiting. "
      if declines_on
        text + "This is the last reminder: if no checkout is recorded it will be automatically declined on " \
               "#{declines_on}. If this was already done in person, please record the checkout."
      else
        text + "If this was already done in person, please record the checkout so this stops."
      end
    end

    def group_message(requests, receipt)
      member = "*#{CheckoutDisplay.escape(receipt.fetch('member_name'))}*"
      shop = "*#{CheckoutDisplay.escape(receipt.fetch('shop_name'))}*"
      day = receipt.fetch('day')
      return "No checkout requests from #{member} for #{shop} on #{day} are still waiting." if requests.empty?

      names = requests.map { |request| target_label(request) }.uniq.sort_by { |name| [name.downcase, name] }
      text = "#{member} requested checkout on #{shop} tools #{names.map { |name| "*#{name}*" }.join(', ')} on #{day} and is still waiting. "
      if receipt['declines_on']
        text += "This is the last reminder. Outstanding requests will be automatically declined on #{receipt['declines_on']}. "
      end
      text + 'If this was already done in person, please record the outstanding checkouts.'
    end

    def resolved_message(request)
      outcome = case request.status
                when 'declined' then request.timed_out? ? 'timed out and was automatically declined' : 'declined'
                when 'deleted' then 'cancelled by the requester'
                else 'approved'
                end
      "Checkout request from *#{CheckoutDisplay.escape(request.member.fullname)}* for " \
        "*#{CheckoutDisplay.escape(request.target&.name)}* (#{request.request_date.to_date.iso8601}) " \
        "is no longer waiting: #{outcome}."
    end

    private

    def target_label(request)
      name = CheckoutDisplay.escape(request.target&.name)
      request.tool_group_id ? "#{name} (tool group)" : name
    end

    def deliver_for!(day, member_id, ids, now, &on_error)
      with_member_lease(member_id) do |check|
        # Resume saved batches with their original UUID before planning fresh posts.
        CheckoutReminderDelivery.where(member_id: member_id, day: day).each do |post|
          ids = ids - post.request_ids
          deliver_post!(post, check, now, &on_error)
        end
        requests = ToolCheckoutRequest.in(id: ids).where(member_id: member_id, status: 'open').includes(:member, :tool, :tool_group).select do |request|
          due?(request, now) && request_day(request) == day
        end
        groups = requests.group_by { |r| [r.target.shop_id || r.id, final_warning?(r)] }
        groups.each do |(_, final_warning), rows|
          first = rows.first
          check.call
          post = CheckoutReminderDelivery.create!(member_id: member_id, day: day, shop_id: first.target.shop_id,
            request_ids: rows.map(&:id), number: due_number(first, now), final_warning: final_warning,
            destination_mode: Service::SlackConnector.message_destination_mode)
          deliver_post!(post, check, now, &on_error)
        end
      end
    end

    def deliver_post!(post, check, now)
      CheckoutReminderSender.deliver!(post, check, now)
    rescue SlackDeliveryLease::Busy
      raise
    rescue => error
      raise unless block_given?
      yield error, post.request_ids
    end
  end
end
