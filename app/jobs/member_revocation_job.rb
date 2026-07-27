class MemberRevocationJob < ApplicationJob
  include Service::BraintreeGateway

  queue_as :critical
  retry_on StandardError, wait: :polynomially_longer, attempts: 7

  def perform(member_id)
    member = Member.find_by(id: member_id)
    return if member.nil? || member.status != "revoked"

    cancel_subscription(member)
    results = Service::MemberAccess.revoke(member)
    failures = results.select { |_provider, result| result[:status] == :error }
    raise "Member access revocation failed: #{failures.inspect}" if failures.present?
  end

  private

  def cancel_subscription(member)
    return if member.subscription_id.blank?

    BraintreeService::Subscription.cancel(connect_gateway, member.subscription_id)
    member.set(subscription_id: nil, subscription: false)
  end
end
