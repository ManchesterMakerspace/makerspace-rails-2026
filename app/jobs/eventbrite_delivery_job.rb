class EventbriteDeliveryJob < ApplicationJob
  def perform(id)
    token = SecureRandom.uuid
    now = Time.current
    selector = { _id: BSON::ObjectId.from_string(id), completed_at: nil, failed_at: nil,
      due_at: { '$lte' => now }, '$or' => [{ lease_until: nil }, { lease_until: { '$lt' => now } }] }
    claimed = EventbriteWebhookDelivery.collection.find(selector).find_one_and_update(
      { '$set' => { lease_token: token, lease_until: now + 120 } }, return_document: :after)
    return unless claimed
    delivery = EventbriteWebhookDelivery.find(id)
    renew = -> { EventbriteWebhookDelivery.where(id: id, lease_token: token).update_all(lease_until: Time.current + 120) == 1 }
    EventbriteIntegration::Lease.with("delivery:#{id}", renew: renew) do |check|
      EventbriteIntegration::Synchronizer.new.refresh(delivery.resource, action: delivery.action, received_at: delivery.created_at)
      check.call
      finish(id, token, completed_at: Time.current, expires_at: 30.days.from_now, last_error: nil)
    end
  rescue EventbriteIntegration::Client::Deferred => error
    finish(id, token, due_at: Time.current + error.delay)
  rescue StandardError => error
    raise unless claimed
    attempts = delivery.attempts + 1
    permanent = error.is_a?(EventbriteIntegration::Client::ApiError) && error.status.between?(400, 499)
    failed = permanent || attempts >= 8
    detail = error.is_a?(EventbriteIntegration::Client::ApiError) ? error.message : error.class.name
    finish(id, token, attempts: attempts, last_error: detail,
      due_at: Time.current + [5 * 2**attempts, 600].min, failed_at: failed ? Time.current : nil)
    Rails.logger.error("Eventbrite delivery #{id}: #{error.class.name}; failed=#{failed}")
  end

  private
  def finish(id, token, attributes)
    EventbriteWebhookDelivery.where(id: id, lease_token: token).update_all(attributes.merge(lease_token: nil, lease_until: nil))
  end
end
