class MailtrapController < ApplicationController
  protect_from_forgery except: [:webhooks]

  def webhooks
    raw_body = request.raw_post
    return unless valid_mailtrap_signature?(raw_body)

    payload = JSON.parse(raw_body)
    process_events(Array.wrap(payload["events"]))

    render json: {}, status: :ok and return
  rescue JSON::ParserError => e
    Rails.logger.error("[Mailtrap] Failed to parse webhook payload: #{e.message}")
    render json: { error: "Invalid JSON payload" }, status: :bad_request and return
  end

  private

  def valid_mailtrap_signature?(raw_body)
    secret = ENV["MAILTRAP_WEBHOOK_SIGNATURE"].to_s
    return true if secret.blank?

    provided_signature = request.headers["Mailtrap-Signature"].to_s
    computed_signature = OpenSSL::HMAC.hexdigest("SHA256", secret, raw_body)
    return true if secure_compare(provided_signature, computed_signature)

    Rails.logger.error("[Mailtrap] Webhook signature validation failed")
    render json: { error: "Invalid signature" }, status: :unauthorized and return false
  end

  def secure_compare(left, right)
    return false if left.blank? || right.blank? || left.bytesize != right.bytesize

    ActiveSupport::SecurityUtils.secure_compare(left, right)
  end

  def process_events(events)
    events.each do |event|
      next unless event.is_a?(Hash)

      recipient_email = event["email"].to_s.strip
      next if recipient_email.blank?

      member = Member.where(email: /\A#{Regexp.escape(recipient_email)}\z/i).first
      next unless member

      mailtrap_event = MailtrapEvent.create!(mailtrap_attributes(event).merge(member_id: member.id))
      member.set(mailtrap_id: mailtrap_event.id)
    end
  end

  def mailtrap_attributes(event)
    attributes = event.deep_dup.deep_transform_keys(&:underscore)
    attributes["status"] = attributes["status"].presence || attributes["event"]
    attributes["occurred_at"] = parse_timestamp(attributes["timestamp"])
    attributes["raw_payload"] = attributes.deep_dup
    attributes.slice(
      "email",
      "status",
      "occurred_at",
      "event",
      "event_id",
      "message_id",
      "response",
      "sending_stream",
      "sending_domain_name",
      "timestamp",
      "raw_payload"
    )
  end

  def parse_timestamp(value)
    return if value.blank?

    zone = Time.zone || ActiveSupport::TimeZone["UTC"]
    zone.at(value.to_i)
  end
end
