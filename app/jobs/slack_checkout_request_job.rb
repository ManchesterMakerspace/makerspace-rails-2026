class SlackCheckoutRequestJob < ApplicationJob
  queue_as :default

  def perform(params)
    response_url     = params['response_url']
    channel_name     = params['channel_name']
    channel_id       = params['channel_id']
    invoker_slack_id = params['user_id']
    tool_name        = params['tool_name'].to_s.strip.presence

    invoker = find_member(invoker_slack_id)
    if invoker.nil?
      synced_member = Service::SlackUserSync.sync_single(invoker_slack_id)
      invoker = find_member(invoker_slack_id) if synced_member
    end

    unless invoker
      post_response(response_url, :ephemeral, "Link your Slack account to a Member Portal account before using `/checkout request`.")
      return
    end

    channel_names = [
      channel_id,
      channel_name,
      Service::SlackChannelCache.normalize_name(channel_name)
    ].compact_blank.uniq
    shop = Shop.where(:slack_channel.in => channel_names).first
    unless shop
      post_response(response_url, :ephemeral, "No shop is configured for ##{channel_name}. Run `/checkout request` from a shop channel.")
      return
    end

    return list_eligible_tools(response_url, invoker, shop) if tool_name.nil?

    tool = Tool.where(shop_id: shop.id).find_by(name: /#{Regexp.escape(tool_name)}/i)
    unless tool
      tool_list = ToolCheckoutRequestEligibility.eligible_tools(member: invoker, shop: shop).map(&:name).join(', ')
      post_response(response_url, :ephemeral, "No eligible tool matching '#{tool_name}' in #{shop.name}. Available: #{tool_list.presence || 'none'}")
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

  def list_eligible_tools(response_url, invoker, shop)
    tools = ToolCheckoutRequestEligibility.eligible_tools(member: invoker, shop: shop)
    if tools.empty?
      post_response(response_url, :ephemeral, "No eligible tools found in #{shop.name}. Your membership must be active (or, if pending, the tool must allow pending members) before requesting a checkout.")
      return
    end

    lines = tools.map { |tool| "• #{tool.name}" }
    post_response(response_url, :ephemeral, "*Eligible tools:*\n#{lines.join("\n")}\n\nUse `/checkout request <tool name>` to request one.")
  end

  def create_request(response_url, invoker, tool)
    error = ToolCheckoutRequestEligibility.new(member: invoker, tool: tool).error
    if error
      post_response(response_url, :ephemeral, error)
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
