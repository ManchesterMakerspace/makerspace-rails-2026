class ReservationFeeNotificationJob < ApplicationJob
  queue_as :default

  def perform(id)
    reservation = Reservation.where(id: id).first
    return unless reservation
    user = SlackUser.find_by(member_id: reservation.member_id)
    return unless user && !reservation.member.direct_notifications_suppressed?

    invoice = reservation.fee_invoice
    zone = ReservationService::ZONE
    resources = reservation.reservation_scope == "shop" ? reservation.shop.name : reservation.tools.map(&:name).join(", ")
    message = "Reservation: #{reservation.title} — #{resources}\n" \
      "#{reservation.start_at.in_time_zone(zone).strftime('%b %-d, %Y %H:%M %Z')} to #{reservation.end_at.in_time_zone(zone).strftime('%b %-d, %Y %H:%M %Z')}\n" \
      "Status: #{reservation.status}."
    if reservation.status == "unpaid" && reservation.decided_at.present? && reservation.approval_reasons.blank?
      message += " Your reservation has been approved; payment is required to make it valid."
    end
    message += "\nNote: #{reservation.decision_note}" if reservation.decision_note.present?
    if invoice
      message += " #{invoice.settled ? 'Paid' : 'Unpaid'}: $#{format('%.2f', invoice.amount)}."
      if invoice.settled
        message += " Payment confirmed."
        message += " This reservation remains #{reservation.status}; payment does not reinstate it." if reservation.cancelled? || reservation.status == "denied"
      elsif reservation.cancelled?
        message += " Your unpaid reservation has been cancelled. The invoice remains payable."
      elsif reservation.status == "denied"
        message += " Your reservation was denied. The invoice remains payable."
      elsif invoice.due_date < Time.current
        message += " Warning: this is not a valid reservation unless the fee is paid before the reservation starts."
      end
      message += "\nPayment due: #{invoice.due_date.in_time_zone(zone).strftime('%b %-d, %Y %H:%M %Z')}." unless invoice.settled
      message += " <#{Rails.configuration.x.app_base_url}/billing/invoices|View invoices>"
    end
    if reservation.notified_at.present?
      begin
        Service::SlackConnector.update_slack_message(reservation.notified_channel_id.presence || user.slack_id, reservation.notified_at, message)
        return
      rescue Slack::Web::Api::Errors::SlackError => error
        raise unless %w[message_not_found channel_not_found cant_update_message].include?(error.message)
      end
    end
    response = Service::SlackConnector.send_slack_message(message, user.slack_id)
    reservation.set(notified_at: response["ts"], notified_channel_id: response["channel"]) if response
  end
end
