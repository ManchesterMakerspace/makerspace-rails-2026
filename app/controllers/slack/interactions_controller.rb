class Slack::InteractionsController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :verify_slack_signature

  def create
    slack_request = nil
    payload = JSON.parse(params[:payload].to_s)
    callback_id = payload.dig("view", "callback_id")
    supported = payload["type"] == "view_submission" ||
      (payload["type"].in?(%w[view_closed block_actions]) && callback_id == "reservation_submit")
    return render json: {} unless supported

    case callback_id
    when "reservation_submit"
      if payload["type"] == "view_closed"
        close_reservation(payload)
      elsif payload["type"] == "block_actions"
        if reservation_policy_action?(payload)
          update_reservation_modal(payload)
        else
          render json: {}
        end
      else
        create_reservation(payload)
      end
    when "checkout_request_submit"
      create_checkout_request(payload)
    else
      render json: {}
    end
  end

  private

  def create_reservation(payload)
    slack_request = nil
    metadata = JSON.parse(payload.dig("view", "private_metadata").to_s)
    state = payload.dig("view", "state", "values") || {}
    member = Member.find(metadata["member_id"])
    date = state.dig("date", "date", "selected_date")
    start_text = state.dig("start_time", "start_time", "selected_time")
    duration = parse_reservation_duration(state.dig("duration", "duration", "selected_option", "value"))
    parsed_date = Date.iso8601(date.to_s)
    if duration[:full_day]
      start_at = ReservationService::ZONE.local(parsed_date.year, parsed_date.month, parsed_date.day)
      end_at = start_at.advance(days: duration[:days])
    else
      start_at = ReservationService::ZONE.parse("#{date} #{start_text}")
      end_at = start_at + duration[:hours].hours
    end

    reservation = ReservationService.create!(
      member: member,
      source: "slack",
      attributes: {
        title: state.dig("title", "title", "value"),
        shop_id: metadata["shop_id"],
        reservation_scope: selected_scope(state),
        tool_ids: selected_tool_ids(state),
        full_day: duration[:full_day],
        start_at: start_at,
        end_at: end_at
      }
    )

    message = reservation_outcome(reservation)
    if reservation.status == "pending" && reservation.effective_approval_details.present?
      reasons = reservation.effective_approval_details.map { |detail| "• #{detail['message']}" }
      message += "\nApproval required because:\n#{reasons.join("\n")}"
    end
    deliver_reservation_outcome(message, metadata, payload)
    render json: { response_action: "clear" }
  rescue ::Error::CustomError => error
    Rails.logger.warn(
      "[SlackReservationRejected] action=create member_id=#{member&.id} reason=#{error.message}"
    )
    render json: {
      response_action: "errors",
      errors: { "duration" => error.message.to_s.first(150) }
    }
  rescue => error
    Rails.logger.error(
      "[SlackReservationError] action=create member_id=#{member&.id} " \
      "error=#{Service::SlackConnector.format_api_error(error, request: slack_request)}"
    )
    Honeybadger.notify(error) if defined?(Honeybadger)
    render json: {
      response_action: "errors",
      errors: {
        "duration" => "The reservation could not be created. Please verify the date and duration and use the Member Portal if the problem continues."
      }
    }
  end

  def update_reservation_modal(payload)
    metadata = JSON.parse(payload.dig("view", "private_metadata").to_s)
    state = payload.dig("view", "state", "values") || {}
    action = payload.fetch("actions").first
    scope = selected_scope(state)
    scope = action.dig("selected_option", "value") if action["action_id"] == SlackReservationModal::SCOPE_ACTION_ID
    tool_ids = selected_tool_ids(state)
    if action["action_id"] == SlackReservationModal::TOOLS_ACTION_ID
      tool_ids = Array(action["selected_options"]).map { |option| option["value"] }
    end
    shop = Shop.find(metadata["shop_id"])
    member = Member.find(metadata["member_id"])
    validate_reservation_tool_ids!(shop, member, tool_ids) if tool_ids.present?
    view = SlackReservationModal.update(
      shop: shop,
      member: member,
      response_url: metadata["response_url"],
      slack_user_id: metadata["slack_user_id"],
      reservation_scope: scope,
      tool_ids: tool_ids,
      title: state.dig("title", "title", "value"),
      date: state.dig("date", "date", "selected_date"),
      start_time: state.dig("start_time", "start_time", "selected_time"),
      duration: state.dig("duration", "duration", "selected_option", "value")
    )
    Service::SlackConnector.update_modal(
      payload.dig("view", "id"),
      view,
      hash: payload.dig("view", "hash")
    )
    render json: {}
  rescue => error
    Service::ErrorReporter.notify(error, context: { phase: "Slack reservation modal policy update" })
    render json: {}
  end

  def reservation_policy_action?(payload)
    payload.fetch("actions", []).any? do |action|
      action["action_id"].in?([
        SlackReservationModal::SCOPE_ACTION_ID,
        SlackReservationModal::TOOLS_ACTION_ID
      ])
    end
  end

  def selected_scope(state)
    state.dig("scope", SlackReservationModal::SCOPE_ACTION_ID, "selected_option", "value") ||
      state.dig("scope", "scope", "selected_option", "value")
  end

  def selected_tool_ids(state)
    selected = state.dig("tools", SlackReservationModal::TOOLS_ACTION_ID, "selected_options") ||
      state.dig("tools", "tools", "selected_options")
    Array(selected).map { |option| option["value"] }
  end

  def validate_reservation_tool_ids!(shop, member, tool_ids)
    requested_ids = Array(tool_ids).map(&:to_s).uniq
    candidates = Tool.where(
      shop_id: shop.id,
      :id.in => requested_ids,
      reservable: true,
      :disabled.ne => true
    ).to_a
    valid_ids = ReservationPolicy.eligible_tools(
      shop: shop,
      member: member,
      tools: candidates
    ).map { |tool| tool.id.to_s }
    return if valid_ids.sort == requested_ids.sort

    raise ::Error::UnprocessableEntity.new("One or more selected tools are no longer reservable in this shop")
  end

  def parse_reservation_duration(value)
    case value.to_s
    when /\Ahours:(\d+(?:\.[05])?)\z/
      hours = Regexp.last_match(1).to_f
      raise ::Error::UnprocessableEntity.new("Select a valid duration") unless hours.positive?

      { full_day: false, hours: hours }
    when /\Adays:(\d+)\z/
      days = Regexp.last_match(1).to_i
      raise ::Error::UnprocessableEntity.new("Select a valid duration") unless days.positive?

      { full_day: true, days: days }
    else
      raise ::Error::UnprocessableEntity.new("Select a valid duration")
    end
  end

  def close_reservation(payload)
    metadata = JSON.parse(payload.dig("view", "private_metadata").to_s)
    deliver_reservation_outcome("Reservation cancelled without submission.", metadata, payload)
    render json: {}
  rescue JSON::ParserError => error
    Service::ErrorReporter.notify(error, context: { phase: "Slack reservation modal closure" })
    render json: {}
  end

  def reservation_outcome(reservation)
    case reservation.status
    when "pending"
      "Reservation *#{reservation.title}* was submitted and is *pending approval*."
    when "unpaid"
      "Reservation *#{reservation.title}* was created, but *payment is required* before it is approved."
    when "approved"
      "Reservation *#{reservation.title}* was created and is *approved*."
    else
      "Reservation *#{reservation.title}* was submitted and is *#{reservation.status}*."
    end
  end

  def deliver_reservation_outcome(message, metadata, payload)
    return if replace_reservation_response(metadata["response_url"], message)

    slack_user_id = payload.dig("user", "id").presence || metadata["slack_user_id"]
    Service::SlackConnector.send_slack_message(message, slack_user_id)
  rescue => error
    report_reservation_delivery_failure(error, {
      phase: "Slack reservation outcome delivery",
      slack_user_id: slack_user_id
    })
  end

  def replace_reservation_response(response_url, message)
    return false if response_url.blank?

    uri = URI.parse(response_url)
    response = Net::HTTP.post(
      uri,
      { response_type: "ephemeral", replace_original: true, text: message }.to_json,
      "Content-Type" => "application/json"
    )
    return true if response.is_a?(Net::HTTPSuccess)

    report_reservation_delivery_failure(
      "Slack reservation response replacement failed",
      { phase: "Slack reservation response replacement", http_status: response.code }
    )
    false
  rescue => error
    report_reservation_delivery_failure(error, { phase: "Slack reservation response replacement" })
    false
  end

  def report_reservation_delivery_failure(error, context)
    Service::ErrorReporter.notify(error, context: context)
  rescue => reporting_error
    Rails.logger.error(
      "[SlackReservationError] action=deliver error=#{error.class} " \
      "reporting_error=#{reporting_error.class}"
    )
  end

  def create_checkout_request(payload)
    state = payload.dig("view", "state", "values") || {}
    metadata = JSON.parse(payload.dig("view", "private_metadata").to_s)
    slack_user = SlackUser.find_by(slack_id: payload.dig("user", "id"))
    member = slack_user && Member.find_by(id: slack_user.member_id)
    return checkout_errors("tool" => "Link an active Member Portal account before requesting a checkout.") unless member

    shop = Shop.find_by(id: metadata["shop_id"])
    tool_id = state.dig("tool", "tool", "selected_option", "value")
    tool = shop && Tool.where(shop_id: shop.id, :disabled.ne => true).find_by(id: tool_id)
    return checkout_errors("tool" => "That shop or tool is no longer available.") unless tool
    unless SlackCheckoutRequestModal.eligible?(member, tool)
      return checkout_errors("tool" => "You are not currently eligible to request this checkout.")
    end
    if ToolCheckout.where(member_id: member.id, tool_id: tool.id, revoked_at: nil).exists?
      return checkout_errors("tool" => "You already have a checkout for this tool.")
    end
    if ToolCheckoutRequest.where(member_id: member.id, tool_id: tool.id, status: "open").exists?
      return checkout_errors("tool" => "You already have an open request for this tool.")
    end

    checkout_request = ToolCheckoutRequest.new(
      member: member, tool: tool, note: state.dig("note", "note", "value"),
      request_date: Time.current, status: "open"
    )
    unless checkout_request.save
      errors = {}
      errors["note"] = checkout_request.errors[:note].join(", ") if checkout_request.errors[:note].present?
      errors["tool"] = checkout_request.errors.full_messages.join(", ").first(150) if errors.empty?
      return checkout_errors(errors)
    end

    checkout_request.announce_request
    begin
      Service::SlackConnector.send_slack_message(checkout_confirmation(shop), slack_user.slack_id)
    rescue => error
      Service::ErrorReporter.notify(error, context: {
        phase: "Slack checkout request confirmation",
        checkout_request_id: checkout_request.id.to_s,
        slack_user_id: slack_user.slack_id
      })
    end
    render json: { response_action: "clear" }
  rescue JSON::ParserError
    checkout_errors("tool" => "The checkout form expired or is invalid. Please open it again.")
  rescue => error
    Service::ErrorReporter.notify(error, context: { phase: "Slack checkout request submission" })
    checkout_errors("tool" => "The request could not be created. Please try again or use the Member Portal.")
  end

  def checkout_confirmation(shop)
    contacts = Member.tagged_resource_managers_for_shop(shop.id).filter_map do |manager|
      slack_user = SlackUser.find_by(member_id: manager.id)
      "<@#{slack_user.slack_id}>" if slack_user&.slack_id.present?
    end
    contact_text = contacts.present? ? contacts.join(", ") : "the shop's resource manager"
    "Your checkout request for *#{shop.name}* was received. Please be patient: checkouts are processed by unpaid volunteers. Interested in helping? Contact #{contact_text} about volunteering as an assistant checkout approver."
  end

  def checkout_errors(errors)
    render json: { response_action: "errors", errors: errors }
  end

  def verify_slack_signature
    secret = ENV["SLACK_SIGNING_SECRET"]
    if secret.blank?
      return if Rails.env.development?

      render json: { error: "Slack signing secret is not configured" },
        status: :forbidden
      return
    end

    timestamp = request.headers["X-Slack-Request-Timestamp"]
    signature = request.headers["X-Slack-Signature"]
    if (Time.now.to_i - timestamp.to_i).abs > 300
      render json: { error: "Request too old" }, status: :forbidden and return
    end

    expected = "v0=#{OpenSSL::HMAC.hexdigest("SHA256", secret, "v0:#{timestamp}:#{request.raw_post}")}"
    unless ActiveSupport::SecurityUtils.secure_compare(expected, signature.to_s)
      render json: { error: "Invalid signature" }, status: :forbidden
    end
  end
end
