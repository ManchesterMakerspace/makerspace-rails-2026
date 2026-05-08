# SlackVolunteerJob
#
# Handles inbound /volunteer Slack slash commands asynchronously.
# Tasks are referenced by sequential number (#N), events by (EN).
#
# Supported commands:
#   /volunteer status [@member]
#   /volunteer tasks                         — list available bounty tasks
#   /volunteer claim <task#>                 — claim a bounty task
#   /volunteer done <task#>                  — mark claimed task as pending verification
#   /volunteer events                        — list open volunteer events
#   /volunteer checkin <E#>                  — check in to an open event
#   /volunteer award @member <reason>        — admin/RM: award a one-off credit
#   /volunteer verify <task#>                — admin/RM: verify a completed task
#   /volunteer release <task#> <reason>      — admin/RM: release a stale claimed task
#   /volunteer reject <task#> <reason>       — admin/RM: reject a pending task
#   /volunteer close <E#>                    — admin/RM: close event and issue credits
#
class SlackVolunteerJob < ApplicationJob
  queue_as :default

  def perform(params)
    response_url     = params['response_url']
    invoker_slack_id = params['user_id']
    text             = params['text'].to_s.strip

    parts   = text.split(/\s+/)
    command = parts[0].to_s.downcase

    invoker = find_member_by_slack_id(invoker_slack_id)
    if invoker.nil?
      Service::SlackUserSync.sync_single(invoker_slack_id)
      invoker = find_member_by_slack_id(invoker_slack_id)
    end

    unless invoker
      post_response(response_url, :ephemeral, '❌ Your Slack account is not linked to a Member Portal account. An admin has been notified.')
      return
    end

    case command
    when 'status'   then handle_status(response_url, invoker, parts[1])
    when 'tasks'    then handle_tasks(response_url)
    when 'claim'    then handle_claim(response_url, invoker, parts[1])
    when 'done'     then handle_done(response_url, invoker, parts[1])
    when 'events'   then handle_events(response_url)
    when 'checkin'  then handle_checkin(response_url, invoker, parts[1])
    when 'award'    then handle_award(response_url, invoker, parts)
    when 'verify'   then handle_verify(response_url, invoker, parts[1])
    when 'release'  then handle_release(response_url, invoker, parts[1], parts[2..].join(' '))
    when 'reject'   then handle_reject(response_url, invoker, parts[1], parts[2..].join(' '))
    when 'close'    then handle_close(response_url, invoker, parts[1])
    else
      post_response(response_url, :ephemeral, usage_text)
    end
  end

  private

  # ── Command Handlers ─────────────────────────────────────────────────────

  def handle_status(response_url, invoker, target_token)
    member = target_token.present? ? find_member_from_token(target_token) : invoker

    unless member
      post_response(response_url, :ephemeral, "❌ Member not found: #{target_token}")
      return
    end

    if member.id != invoker.id && !privileged?(invoker)
      post_response(response_url, :ephemeral, '❌ You can only check your own status.')
      return
    end

    year_count      = VolunteerCredit.year_count_for(member.id)
    pending_count   = VolunteerCredit.pending.where(member_id: member.id).count
    discount_active = VolunteerCredit.discount_amount > 0.0
    is_earned       = EarnedMembership.where(member_id: member.id).exists?

    lines = ["📊 *Volunteer Status for #{member.fullname}*"]
    lines << "Credits this year: *#{year_count}*"
    lines << "Pending approval: #{pending_count}" if pending_count > 0

    if discount_active && !is_earned
      discounts_used = VolunteerCredit.discounts_applied_this_year_for(member.id)
      threshold      = VolunteerCredit.credits_per_discount
      max_discounts  = VolunteerCredit.max_discounts_per_year
      lines << "Discounts applied: *#{discounts_used}* / #{max_discounts}"
      if discounts_used >= max_discounts
        lines << '🏆 Maximum discounts reached for this year. Resets January 1st.'
      else
        credits_until_next = [(threshold * (discounts_used + 1)) - year_count, 0.0].max
        lines << "#{credits_until_next} credit#{'s' if credits_until_next != 1.0} until next discount."
      end
    elsif is_earned && discount_active
      lines << '_Earned membership — credits logged for recognition only._'
    end

    post_response(response_url, :ephemeral, lines.join("\n"))
  end

  def handle_tasks(response_url)
    tasks = VolunteerTask.available.order_by(task_number: :asc).limit(10)

    if tasks.empty?
      post_response(response_url, :ephemeral, '📋 No bounty tasks are currently available.')
      return
    end

    lines = ['📋 *Available Bounty Tasks*']
    tasks.each do |t|
      credit_label = t.credit_value == 1.0 ? '1 credit' : "#{t.credit_value} credits"
      lines << "• *#{t.title}* (#{credit_label}) — `#{t.display_number}`\n  #{t.description}"
    end
    lines << "\nUse `/volunteer claim <task#>` to claim one. e.g. `/volunteer claim 3`"

    post_response(response_url, :ephemeral, lines.join("\n"))
  end

  def handle_claim(response_url, invoker, task_ref)
    unless task_ref.present?
      post_response(response_url, :ephemeral, 'Usage: `/volunteer claim <task#>` e.g. `/volunteer claim 3`')
      return
    end

    task = find_task_by_ref(task_ref)
    unless task
      post_response(response_url, :ephemeral, "❌ Task not found: #{task_ref}. Use `/volunteer tasks` to see available tasks.")
      return
    end

    unless task.status == 'available'
      post_response(response_url, :ephemeral, "❌ Task *#{task.title}* is not available (status: #{task.status}).")
      return
    end

    task.claim!(invoker)
    post_response(response_url, :ephemeral,
      "🙌 You've claimed *#{task.title}* (#{task.display_number}). When you're done, use `/volunteer done #{task.task_number}`")
  end

  def handle_done(response_url, invoker, task_ref)
    unless task_ref.present?
      post_response(response_url, :ephemeral, 'Usage: `/volunteer done <task#>` e.g. `/volunteer done 3`')
      return
    end

    task = find_task_by_ref(task_ref)
    unless task
      post_response(response_url, :ephemeral, "❌ Task not found: #{task_ref}.")
      return
    end

    unless task.claimed_by_id == invoker.id
      post_response(response_url, :ephemeral, "❌ You haven't claimed this task.")
      return
    end

    task.mark_pending!(invoker)

    ::Service::SlackConnector.send_slack_message(
      "✅ *#{invoker.fullname}* completed task *#{task.title}* (#{task.display_number}) and is awaiting verification.",
      VolunteerCredit.pending_slack_channel
    )

    post_response(response_url, :ephemeral,
      "✅ Task *#{task.title}* marked as complete. An admin or RM will verify shortly.")
  end

  def handle_events(response_url)
    events = VolunteerEvent.active_events.order_by(event_number: :asc).limit(10)

    if events.empty?
      post_response(response_url, :ephemeral, '📅 No volunteer events are currently open.')
      return
    end

    lines = ['📅 *Open Volunteer Events*']
    events.each do |e|
      credit_label = e.credit_value == 1.0 ? '1 credit' : "#{e.credit_value} credits"
      date_str     = e.event_date ? " — #{e.event_date.strftime('%b %d')}" : ''
      lines << "• *#{e.title}* (#{credit_label}#{date_str}) — `#{e.display_number}` — #{e.attendee_count} checked in\n  #{e.description}"
    end
    lines << "\nUse `/volunteer checkin <E#>` to check in. e.g. `/volunteer checkin E1`"

    post_response(response_url, :ephemeral, lines.join("\n"))
  end

  def handle_checkin(response_url, invoker, event_ref)
    unless event_ref.present?
      post_response(response_url, :ephemeral, 'Usage: `/volunteer checkin <E#>` e.g. `/volunteer checkin E1`')
      return
    end

    event = find_event_by_ref(event_ref)
    unless event
      post_response(response_url, :ephemeral, "❌ Event not found: #{event_ref}. Use `/volunteer events` to see open events.")
      return
    end

    event.checkin!(invoker)
    post_response(response_url, :ephemeral,
      "✅ You're checked in to *#{event.title}* (#{event.display_number}). Credits will be issued when the event closes.")
  rescue Error::Forbidden => e
    post_response(response_url, :ephemeral, "❌ #{e.message}")
  end

  def handle_award(response_url, invoker, parts)
    unless privileged?(invoker)
      post_response(response_url, :ephemeral, '❌ Only admins and resource managers can award credits.')
      return
    end

    if parts.length < 3
      post_response(response_url, :ephemeral, 'Usage: `/volunteer award @member <reason>`')
      return
    end

    member = find_member_from_token(parts[1])
    unless member
      post_response(response_url, :ephemeral, "❌ Member not found: #{parts[1]}")
      return
    end

    if member.id == invoker.id
      post_response(response_url, :ephemeral, '❌ You cannot award a credit to yourself.')
      return
    end

    description = parts[2..].join(' ')
    credit = VolunteerCredit.create!(
      member_id:    member.id,
      issued_by_id: invoker.id,
      description:  description,
      credit_value: 1.0,
      status:       'approved'
    )
    credit.send(:notify_member_credit_awarded)
    credit.send(:check_discount_threshold!)

    post_response(response_url, :in_channel,
      "🌟 *#{invoker.fullname}* awarded a volunteer credit to *#{member.fullname}*: _#{description}_")
  end

  def handle_verify(response_url, invoker, task_ref)
    unless privileged?(invoker)
      post_response(response_url, :ephemeral, '❌ Only admins and resource managers can verify tasks.')
      return
    end

    unless task_ref.present?
      post_response(response_url, :ephemeral, 'Usage: `/volunteer verify <task#>`')
      return
    end

    task = find_task_by_ref(task_ref)
    unless task
      post_response(response_url, :ephemeral, "❌ Task not found: #{task_ref}.")
      return
    end

    unless task.status == 'pending'
      post_response(response_url, :ephemeral, "❌ Task *#{task.title}* is not pending verification (status: #{task.status}).")
      return
    end

    if task.claimed_by_id == invoker.id
      post_response(response_url, :ephemeral, '❌ You cannot verify your own task.')
      return
    end

    task.complete!(invoker)
    claimant = Member.find(task.claimed_by_id) rescue nil

    post_response(response_url, :in_channel,
      "✅ *#{invoker.fullname}* verified task *#{task.title}* (#{task.display_number}) complete for *#{claimant&.fullname || 'member'}*. Credit issued!")
  end

  def handle_release(response_url, invoker, task_ref, reason)
    unless privileged?(invoker)
      post_response(response_url, :ephemeral, '❌ Only admins and resource managers can release tasks.')
      return
    end

    unless task_ref.present? && reason.present?
      post_response(response_url, :ephemeral, 'Usage: `/volunteer release <task#> <reason>`')
      return
    end

    task = find_task_by_ref(task_ref)
    unless task
      post_response(response_url, :ephemeral, "❌ Task not found: #{task_ref}.")
      return
    end

    unless task.status == 'claimed'
      post_response(response_url, :ephemeral, "❌ Task *#{task.title}* is not currently claimed.")
      return
    end

    task.release!(invoker, reason)
    post_response(response_url, :in_channel,
      "🔓 Task *#{task.title}* (#{task.display_number}) has been released. Reason: #{reason}")
  rescue Error::Forbidden
    post_response(response_url, :ephemeral, '❌ You cannot release your own claimed task.')
  end

  def handle_reject(response_url, invoker, task_ref, reason)
    unless privileged?(invoker)
      post_response(response_url, :ephemeral, '❌ Only admins and resource managers can reject tasks.')
      return
    end

    unless task_ref.present? && reason.present?
      post_response(response_url, :ephemeral, 'Usage: `/volunteer reject <task#> <reason>`')
      return
    end

    task = find_task_by_ref(task_ref)
    unless task
      post_response(response_url, :ephemeral, "❌ Task not found: #{task_ref}.")
      return
    end

    unless task.status == 'pending'
      post_response(response_url, :ephemeral, "❌ Task *#{task.title}* is not pending verification.")
      return
    end

    task.reject_pending!(invoker, reason)
    post_response(response_url, :in_channel,
      "❌ Task *#{task.title}* (#{task.display_number}) rejected. Reason: #{reason}. Available for reclaiming.")
  rescue Error::Forbidden
    post_response(response_url, :ephemeral, '❌ You cannot reject your own task.')
  end

  def handle_close(response_url, invoker, event_ref)
    unless privileged?(invoker)
      post_response(response_url, :ephemeral, '❌ Only admins and resource managers can close events.')
      return
    end

    unless event_ref.present?
      post_response(response_url, :ephemeral, 'Usage: `/volunteer close <E#>` e.g. `/volunteer close E1`')
      return
    end

    event = find_event_by_ref(event_ref)
    unless event
      post_response(response_url, :ephemeral, "❌ Event not found: #{event_ref}.")
      return
    end

    unless event.status == 'open'
      post_response(response_url, :ephemeral, "❌ Event *#{event.title}* is already closed.")
      return
    end

    attendee_count = event.attendee_count
    event.close!(invoker)

    post_response(response_url, :in_channel,
      "🎉 *#{invoker.fullname}* closed event *#{event.title}* (#{event.display_number}). " \
      "#{attendee_count} member#{'s' if attendee_count != 1} received #{event.credit_value} credit#{'s' if event.credit_value != 1.0}!")
  rescue Error::Forbidden => e
    post_response(response_url, :ephemeral, "❌ #{e.message}")
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  def find_task_by_ref(ref)
    number = ref.to_s.sub(/\A#/, '').to_i
    return nil if number == 0
    VolunteerTask.find_by_number(number)
  rescue
    nil
  end

  def find_event_by_ref(ref)
    number = ref.to_s.upcase.sub(/\AE/, '').to_i
    return nil if number == 0
    VolunteerEvent.find_by_number(number)
  rescue
    nil
  end

  def usage_text
    <<~TEXT
      *Volunteer Commands:*
      `/volunteer status [@member]` — Check credit status
      `/volunteer tasks` — List available bounty tasks
      `/volunteer claim <task#>` — Claim a task e.g. `/volunteer claim 3`
      `/volunteer done <task#>` — Mark your task complete
      `/volunteer events` — List open volunteer events
      `/volunteer checkin <E#>` — Check in to an event e.g. `/volunteer checkin E1`
      `/volunteer award @member <reason>` — _(admin/RM)_ Award a one-off credit
      `/volunteer verify <task#>` — _(admin/RM)_ Verify a completed task
      `/volunteer release <task#> <reason>` — _(admin/RM)_ Release a stale task
      `/volunteer reject <task#> <reason>` — _(admin/RM)_ Reject a pending task
      `/volunteer close <E#>` — _(admin/RM)_ Close event and issue credits
    TEXT
  end

  def privileged?(member)
    member.role.in?(%w[admin resource_manager])
  end

  def find_member_by_slack_id(slack_id)
    slack_user = SlackUser.find_by(slack_id: slack_id)
    return nil unless slack_user
    Member.find(slack_user.member_id) rescue nil
  end

  def find_member_from_token(token)
    if token.start_with?('<@')
      slack_id   = token.match(/<@([^|>]+)/i)&.captures&.first
      slack_user = SlackUser.find_by(slack_id: slack_id)
      slack_user ? (Member.find(slack_user.member_id) rescue nil) : nil
    elsif token.start_with?('@')
      username   = token.sub(/\A@/, '')
      slack_user = SlackUser.where(name: /\A#{Regexp.escape(username)}\z/i).first
      slack_user ? (Member.find(slack_user.member_id) rescue nil) : nil
    else
      Member.find_by(email: token.downcase)
    end
  end

  def post_response(response_url, response_type, text)
    uri  = URI.parse(response_url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == 'https'
    req  = Net::HTTP::Post.new(uri.request_uri, 'Content-Type' => 'application/json')
    req.body = { response_type: response_type, text: text }.to_json
    http.request(req)
  rescue => err
    Honeybadger.notify('SlackVolunteerJob: failed to post response', context: {
      error: err.message, response_url: response_url
    }) if defined?(Honeybadger)
  end
end
