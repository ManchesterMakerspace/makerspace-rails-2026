class Slack::InteractionsController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :verify_slack_signature

  def create
    slack_request = nil
    payload = JSON.parse(params[:payload].to_s)
    return render json: {} unless payload["type"] == "view_submission"

    case payload.dig("view", "callback_id")
    when "reservation_submit"
      create_reservation(payload)
    when "checkout_request_submit"
      create_checkout_request(payload)
    else
      render json: {}
    end
  end

  private

  def create_reservation(payload)
    metadata = JSON.parse(payload.dig("view", "private_metadata").to_s)
    state = payload.dig("view", "state", "values") || {}
    member = Member.find(metadata["member_id"])
    date = state.dig("date", "date", "selected_date")
    start_text = state.dig("start_time", "start_time", "selected_time")
    end_text = state.dig("end_time", "end_time", "selected_time")
    start_at = ReservationService::ZONE.parse("#{date} #{start_text}")
    end_at = ReservationService::ZONE.parse("#{date} #{end_text}")
    end_at += 1.day if end_at <= start_at

    reservation = ReservationService.create!(
      member: member,
      source: "slack",
      attributes: {
        title: state.dig("title", "title", "value"),
        shop_id: metadata["shop_id"],
        reservation_scope: state.dig("scope", "scope", "selected_option", "value"),
        tool_ids: Array(state.dig("tools", "tools", "selected_options")).map { |option| option["value"] },
        start_at: start_at,
        end_at: end_at
      }
    )

    message = "Reservation *#{reservation.title}* was submitted and is *#{reservation.status}*."
    if reservation.status == "pending" && reservation.effective_approval_details.present?
      reasons = reservation.effective_approval_details.map { |detail| "• #{detail['message']}" }
      message += "\nApproval required because:\n#{reasons.join("\n")}"
    end
    slack_request = {
      method: "chat.postMessage",
      arguments: { channel: payload.dig("user", "id"), text: message }
    }
    Service::SlackConnector.send_slack_message(message, payload.dig("user", "id"))
    render json: { response_action: "clear" }
  rescue ::Error::CustomError => error
    Rails.logger.warn(
      "[SlackReservationRejected] action=create member_id=#{member&.id} reason=#{error.message}"
    )
    render json: {
      response_action: "errors",
      errors: { "end_time" => error.message.to_s.first(150) }
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
        "end_time" => "The reservation could not be created. Please verify the times and use the Member Portal if the problem continues."
      }
    }
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
    Service::SlackConnector.send_slack_message(checkout_confirmation(shop), slack_user.slack_id)
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
