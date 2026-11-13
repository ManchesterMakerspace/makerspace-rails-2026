class EventbriteWebhooksController < ActionController::Base
  skip_forgery_protection only: :create
  # The global parameter normalizer parses JSON before the action/rescue chain.
  def process_action(*)
    super
  rescue ActionDispatch::Http::Parameters::ParseError
    head :bad_request
  end
  # This machine-to-machine endpoint has no session or CSRF credentials.
  def create
    return head :unsupported_media_type unless request.media_type == 'application/json'
    return head :payload_too_large if request.raw_post.bytesize > 65_536
    body = JSON.parse(request.raw_post)
    return head :bad_request unless body.is_a?(Hash)
    action = body.dig('config', 'action')
    return head :ok if action == 'test'
    resource = EventbriteIntegration::Resource.parse(body['api_url'])
    if action.present?
      known = EventbriteIntegration::Resource::ACTIONS.values.flatten
      return head :no_content unless known.include?(action)
      return head :bad_request unless EventbriteIntegration::Resource::ACTIONS.fetch(resource['type']).include?(action)
    end
    delivery = EventbriteWebhookDelivery.create!(resource: resource, action: action)
    begin
      EventbriteDeliveryJob.perform_later(delivery.id.to_s)
    rescue StandardError
      # The persisted inbox is recovered independently of the async adapter.
      Rails.logger.warn('Eventbrite delivery persisted; enqueue deferred to recovery')
    end
    head :accepted
  rescue JSON::ParserError, ArgumentError, TypeError
    head :bad_request
  rescue StandardError
    head :service_unavailable
  end
end
