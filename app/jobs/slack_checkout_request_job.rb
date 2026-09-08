class SlackCheckoutRequestJob < ApplicationJob
  queue_as :default

  MAX_TOOL_LIST = 40

  def perform(params)
    response_url    = params['response_url']
    invoker_slack_id = params['user_id']
    tool_name       = params['tool_name'].to_s.strip.presence

    invoker = find_member(invoker_slack_id)
    if invoker.nil?
      synced_member = Service::SlackUserSync.sync_single(invoker_slack_id)
      invoker = find_member(invoker_slack_id) if synced_member
    end

    unless invoker
      post_response(response_url, :ephemeral, "Link your Slack account to a Member Portal account before using `/checkout request`.")
      return
    end

    return list_eligible_tools(response_url, invoker) if tool_name.nil?

    tool = Tool.where(:disabled.ne => true).find_by(name: /#{Regexp.escape(tool_name)}/i)
    unless tool
      post_response(response_url, :ephemeral, "No eligible tool matching '#{tool_name}'. Run `/checkout request` with no arguments to see eligible tools.")
      return
    end

    existing_checkout = ToolCheckout.where(member_id: invoker.id, tool_id: tool.id, revoked_at: nil).first
    if existing_checkout
      existing_checkout.send_notes_slack_notification
      post_response(response_url, :ephemeral, "You're already checked out on *#{tool.name}*#{tool.notes.present? ? ' — notes re-sent via DM.' : '.'}")
      return
    end

    create_request(response_url, invoker, tool)
  rescue => e
    Service::ErrorReporter.notify(e, context: { phase: 'slack checkout request', invoker_slack_id: invoker_slack_id, tool_name: tool_name })
    post_response(response_url, :ephemeral, 'Something went wrong processing your request. Please try again or use the Member Portal.')
  end

  private

  def find_member(slack_id)
    slack_user = SlackUser.find_by(slack_id: slack_id)
    return nil unless slack_user
    Member.find(slack_user.member_id)
  end

  def eligible?(member, tool)
    return false if tool.disabled?
    if member.status == 'pending'
      tool.allow_pending
    else
      member.active_unexpired? && member.status == 'activeMember'
    end
  end

  def list_eligible_tools(response_url, invoker)
    tools = Tool.where(:disabled.ne => true).order_by(name: :asc).select { |tool| eligible?(invoker, tool) }.first(MAX_TOOL_LIST)
    if tools.empty?
      post_response(response_url, :ephemeral, "No eligible tools found. Your membership must be active (or, if pending, the tool must allow pending members) before requesting a checkout.")
      return
    end

    lines = tools.map do |tool|
      checked_out = ToolCheckout.where(member_id: invoker.id, tool_id: tool.id, revoked_at: nil).exists?
      "• #{tool.name}#{checked_out ? ' _(already checked out — resends notes)_' : ''}"
    end
    post_response(response_url, :ephemeral, "*Eligible tools:*\n#{lines.join("\n")}\n\nUse `/checkout request <tool name>` to request one.")
  end

  def create_request(response_url, invoker, tool)
    unless eligible?(invoker, tool)
      post_response(response_url, :ephemeral, "Your membership must first be activated and you must complete your Orientation checkout before requesting *#{tool.name}*.")
      return
    end

    if ToolCheckoutRequest.where(member_id: invoker.id, tool_id: tool.id, status: 'open').exists?
      post_response(response_url, :ephemeral, "You already have an open request for *#{tool.name}*.")
      return
    end

    request = ToolCheckoutRequest.create!(
      member_id: invoker.id,
      tool_id: tool.id,
      request_date: Time.now,
      status: 'open'
    )
    request.announce_request

    post_response(response_url, :ephemeral, "Requested checkout on *#{tool.name}*. An approver will be notified.")
  end

  def post_response(response_url, response_type, text)
    return if response_url.blank?

    uri  = URI.parse(response_url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == 'https'
    req  = Net::HTTP::Post.new(uri.request_uri, 'Content-Type' => 'application/json')
    req.body = { response_type: response_type, text: text }.to_json
    http.request(req)
  rescue => err
    Service::ErrorReporter.notify('Slack checkout request: failed to post response to response_url', context: {
      error: err.message,
      response_url: response_url,
      text: text
    })
  end
end
