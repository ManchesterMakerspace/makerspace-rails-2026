class FixTicketDeliveryRecoveryJob < ApplicationJob
  queue_as :default
  def perform
    FixTicketEvent.where(completed_at: nil).distinct(:ticket_id).each do |id|
      FixTicketDeliveryJob.perform_later(id.to_s)
    end
  end
end
