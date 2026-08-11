class Slack::EventsController < ApplicationController
  EVENT_DEDUPLICATION_TTL = 7.days.to_i

  skip_before_action :verify_authenticity_token
  before_action :verify_slack_signature

  def create
    payload = JSON.parse(request.raw_post)
    return render json: { challenge: payload['challenge'] } if payload['type'] == 'url_verification'
    return head :ok unless payload['type'] == 'event_callback'

    event = payload['event'] || {}
    return head :ok unless %w[team_join user_change].include?(event['type'])

    event_id = payload['event_id'].to_s
    return render json: { error: 'Missing event_id' }, status: :bad_request if event_id.blank?

    deduplication_key = "slack_event/#{Digest::SHA256.hexdigest(event_id)}"
    acquired = REDIS.set(deduplication_key, 1, nx: true, ex: EVENT_DEDUPLICATION_TTL)
    return head :ok unless acquired

    begin
      SlackUserEventJob.perform_later(event_id, event)
    rescue
      REDIS.del(deduplication_key)
      raise
    end
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
