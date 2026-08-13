class Slack::EventsController < ApplicationController
  EVENT_DEDUPLICATION_TTL = 7.days.to_i
  ACTIVE_ATTEMPT_WAIT = 2.seconds
  ACTIVE_ATTEMPT_POLL_INTERVAL = 0.05.seconds
  PROCESSING_STATE = 'processing'
  COMPLETED_STATE = 'completed'

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
    acquisition = acquire_event(deduplication_key)
    return head :ok if acquisition == :completed
    return head :service_unavailable unless acquisition == :acquired

    begin
      # No durable Active Job adapter is configured in production. Process
      # before acknowledging so Slack will redeliver if persistence or a side
      # effect fails; the deduplication key is released in that case.
      Service::SlackUserEvents.process(event, event_id: event_id)
      REDIS.set(deduplication_key, COMPLETED_STATE, xx: true, ex: EVENT_DEDUPLICATION_TTL)
    rescue
      REDIS.del(deduplication_key)
      raise
    end
    head :ok
  rescue JSON::ParserError
    render json: { error: 'Invalid JSON' }, status: :bad_request
  end

  private

  # A callback that arrives while the first attempt is still running must not
  # receive a successful acknowledgement until that attempt succeeds. Wait
  # briefly for completion; returning 503 after the wait asks Slack to retry.
  def acquire_event(key)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + ACTIVE_ATTEMPT_WAIT

    loop do
      return :acquired if REDIS.set(key, PROCESSING_STATE, nx: true, ex: EVENT_DEDUPLICATION_TTL)
      return :completed if REDIS.get(key) == COMPLETED_STATE
      return :in_progress if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep ACTIVE_ATTEMPT_POLL_INTERVAL
    end
  end

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
