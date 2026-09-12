class FixTicketDeliveryJob < ApplicationJob
  queue_as :default
  retry_on StandardError, wait: :polynomially_longer, attempts: 8
  def perform(ticket_id)
    ticket = FixTicket.where(id: ticket_id).first
    return unless ticket
    FixTicketDeliveryLease.with(ticket_id) do
      FixTicketEvent.where(ticket_id: ticket.id, completed_at: nil).order_by(revision: :asc).each do |event|
        FixTicketDelivery.call(ticket.reload, event)
      end
    end
  end
end
