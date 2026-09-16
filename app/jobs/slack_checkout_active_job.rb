class SlackCheckoutActiveJob < ApplicationJob
  queue_as :default

  def perform(params)
    response_url = params["response_url"]
    slack_user = SlackUser.find_by(slack_id: params["user_id"])
    member = slack_user && Member.find_by(id: slack_user.member_id)
    unless member
      Service::SlackUserSync.sync_single(params["user_id"])
      slack_user = SlackUser.find_by(slack_id: params["user_id"])
      member = slack_user && Member.find_by(id: slack_user.member_id)
    end
    return post_response(response_url, "Link your Slack account to a Member Portal account first.") unless member

    channel_names = [
      params["channel_id"],
      params["channel_name"],
      Service::SlackChannelCache.normalize_name(params["channel_name"])
    ].compact_blank.uniq
    channel_shop = Shop.where(:slack_channel.in => channel_names).first
    all_shops = params["text"].to_s.split(/\s+/)[1].to_s.casecmp("all").zero? || channel_shop.nil?
    checkouts = ToolCheckout.where(member_id: member.id, revoked_at: nil).to_a
    checkouts.select! { |checkout| checkout.tool&.shop_id.to_s == channel_shop.id.to_s } unless all_shops

    grouped = checkouts.group_by { |checkout| checkout.tool&.shop }.reject { |shop, _| shop.nil? }
    grouped.select! { |shop, _| shop.id.to_s == channel_shop.id.to_s } unless all_shops
    if grouped.empty?
      scope = all_shops ? "any shop" : channel_shop.name
      return post_response(response_url, "You have no active tool checkouts in #{scope}.")
    end

    sections = grouped.sort_by { |shop, _| shop.name.to_s.downcase }.map do |shop, rows|
      heading = all_shops ? "*#{shop.name}* (#{shop_channel(shop)})\n" : ""
      heading + checkout_table(member, rows)
    end
    post_response(response_url, sections.join("\n\n"))
  rescue => error
    Service::ErrorReporter.notify(error, context: { phase: "slack active checkouts", slack_id: params["user_id"] })
    post_response(response_url, "Something went wrong looking up your active checkouts. Please use the Member Portal.")
  end

  private

  def checkout_table(member, checkouts)
    rows = checkouts.sort_by { |checkout| checkout.tool.name.to_s.downcase }.map do |checkout|
      tool = checkout.tool
      [tool.name, tool_status(tool), approver?(member, tool) ? "Yes" : "No"]
    end
    widths = ["Tool".length, "Status".length, "Approver".length]
    rows.each { |row| row.each_with_index { |value, index| widths[index] = [widths[index], value.length].max } }
    line = ->(row) { row.each_with_index.map { |value, index| value.ljust(widths[index]) }.join(" | ") }
    "```#{line.call(%w[Tool Status Approver])}\n#{widths.map { |width| "-" * width }.join("-+-")}\n#{rows.map { |row| line.call(row) }.join("\n")}```"
  end

  def tool_status(tool)
    tool.disabled? || tool.shop&.disabled? ? "Disabled" : "Enabled"
  end

  def approver?(member, tool)
    member.role.in?(%w[admin board_member]) || member.manages_shop?(tool.shop_id) ||
      (!tool.disabled? && member.valid_for_checkout_request? &&
        CheckoutApprover.find_by(member_id: member.id)&.can_approve_tool?(tool))
  end

  def shop_channel(shop)
    shop.slack_channel.present? ? "##{Service::SlackChannelCache.normalize_name(shop.slack_channel)}" : "no Slack channel"
  end

  def post_response(response_url, text)
    return if response_url.blank?
    uri = URI.parse(response_url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    request = Net::HTTP::Post.new(uri.request_uri, "Content-Type" => "application/json")
    request.body = { response_type: :ephemeral, text: text }.to_json
    http.request(request)
  end
end
