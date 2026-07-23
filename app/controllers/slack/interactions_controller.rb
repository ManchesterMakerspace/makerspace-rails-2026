class Slack::InteractionsController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :verify_slack_signature

  def create
    payload = JSON.parse(params[:payload].to_s)
    return render json: {} unless payload["type"] == "view_submission" &&
      payload.dig("view", "callback_id") == "reservation_submit"

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

    Service::SlackConnector.send_slack_message(
      "Reservation *#{reservation.title}* was submitted and is *#{reservation.status}*.",
      payload.dig("user", "id")
    )
    render json: { response_action: "clear" }
  rescue ::Error::CustomError => error
    render json: {
      response_action: "errors",
      errors: { "end_time" => error.message.to_s.first(150) }
    }
  rescue => error
    Honeybadger.notify(error) if defined?(Honeybadger)
    render json: {
      response_action: "errors",
      errors: { "end_time" => "Unable to create this reservation." }
    }
  end

  private

  def verify_slack_signature
    secret = ENV["SLACK_SIGNING_SECRET"]
    return if secret.blank?

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
