class MemberBillingSyncJob < ApplicationJob
  include Service::BraintreeGateway

  queue_as :integrations
  retry_on StandardError, wait: :polynomially_longer, attempts: 5

  def perform(member_id)
    member = Member.find_by(id: member_id)
    return if member.nil? || member.customer_id.blank?

    connect_gateway.customer.update(
      member.customer_id,
      first_name: member.firstname,
      last_name: member.lastname
    )
  end
end
