class MailtrapController < ApplicationController
  skip_before_action :verify_authenticity_token

  # POST /mailtrap_listener
  def webhooks
    raw_body = request.body.read
    return unless valid_mailtrap_signature?(raw_body)

    events = parse_events(params)
    events.each { |event| process_event(event) }

    render json: { received: events.length }, status: :ok
  end

  private

  def parse_events(params)
    # Mailtrap sends either a single event or an array
    if params[:events].present?
      params[:events]
    elsif params[:event].present?
      [params]
    else
      []
    end
  end

  def process_event(event)
    email      = event[:email].to_s.downcase.strip
    event_id   = event[:event_id].to_s
    message_id = event[:message_id].to_s
    status     = event[:status].to_s
    occurred_at = event[:occurred_at] ? Time.parse(event[:occurred_at].to_s) : Time.now

    return if email.blank? || event_id.blank?

    # Find the member by email
    member = Member.where(email: email).first
    return unless member

    # Attempt to match the send-time MailtrapMessage record by message_id
    # so the event can surface the subject. Nil is acceptable — webhooks may
    # arrive for emails sent before this feature was deployed.
    mailtrap_message = message_id.present? ? MailtrapMessage.where(message_id: message_id).first : nil

    # Create the delivery event record
    mailtrap_event = MailtrapEvent.create(
      email:               email,
      status:              status,
      event:               event[:event].to_s,
      event_id:            event_id,
      message_id:          message_id,
      occurred_at:         occurred_at,
      sending_stream:      event[:sending_stream].to_s,
      sending_domain_name: event[:sending_domain_name].to_s,
      timestamp:           event[:timestamp],
      member_id:           member.id,
      mailtrap_message_id: mailtrap_message&.id,
      raw_payload:         event.to_unsafe_h
    )

    # Keep mailtrap_id pointing at the latest event for the status icon on member list
    member.set(mailtrap_id: mailtrap_event.id)
  rescue => e
    Rails.logger.error("[MailtrapController] process_event failed for event_id=#{event[:event_id]}: #{e.message}")
    Honeybadger.notify(e) if defined?(Honeybadger)
  end

  def valid_mailtrap_signature?(raw_body)
    secret = ENV['MAILTRAP_WEBHOOK_SIGNATURE']
    return true if secret.blank?

    signature = request.headers['Signature'] || request.headers['X-Mailtrap-Signature']
    if signature.blank?
      render json: { error: 'Missing signature' }, status: :unauthorized
      return false
    end

    expected = OpenSSL::HMAC.hexdigest('SHA256', secret, raw_body)
    unless ActiveSupport::SecurityUtils.secure_compare(expected, signature)
      render json: { error: 'Invalid signature' }, status: :unauthorized
      return false
    end

    true
  end
end
