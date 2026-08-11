class Slack::EventsController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :verify_slack_signature

  def create
    payload = JSON.parse(request.raw_post)
    return render json: { challenge: payload['challenge'] } if payload['type'] == 'url_verification'

    event = payload['event'] || {}
    SlackUserEventJob.perform_later(event) if %w[team_join user_change].include?(event['type'])
    head :ok
  rescue JSON::ParserError
    render json: { error: 'Invalid JSON' }, status: :bad_request
  end

  private

  def verify_slack_signature
    secret = ENV['SLACK_SIGNING_SECRET']
    if secret.blank?
      render json: { error: 'Slack signing secret is not configured' }, status: :forbidden
      return
    end

    timestamp = request.headers['X-Slack-Request-Timestamp']
    signature = request.headers['X-Slack-Signature']
    if timestamp.blank? || (Time.now.to_i - timestamp.to_i).abs > 300
      render json: { error: 'Request too old' }, status: :forbidden
      return
    end

    expected = "v0=#{OpenSSL::HMAC.hexdigest('SHA256', secret, "v0:#{timestamp}:#{request.raw_post}")}"
    unless ActiveSupport::SecurityUtils.secure_compare(expected, signature.to_s)
      render json: { error: 'Invalid signature' }, status: :forbidden
    end
  end
end
