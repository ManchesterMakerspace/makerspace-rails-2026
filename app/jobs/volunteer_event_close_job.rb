class VolunteerEventCloseJob < ApplicationJob
  queue_as :integrations
  retry_on StandardError, wait: :polynomially_longer, attempts: 5

  def perform(event_id)
    event = VolunteerEvent.find_by(id: event_id)
    return if event.nil? || event.status != "closed"

    members = Member.where(
      :id.in => event.attendee_ids,
      status: "activeMember"
    ).to_a.index_by(&:id)

    event.attendee_ids.each do |member_id|
      next unless members.key?(member_id)

      next if VolunteerCredit.where(event_id: event.id, member_id: member_id).exists?

      credit = VolunteerCredit.create!(
        event_id: event.id,
        member_id: member_id,
        issued_by_id: event.closed_by_id,
        description: "Attended event: #{event.title} (#{event.display_number})",
        credit_value: event.credit_value,
        status: "approved"
      )
      credit.send(:notify_member_credit_awarded)
      credit.send(:check_discount_threshold!)
    rescue => error
      Honeybadger.notify(error) if defined?(Honeybadger)
    end
  end
end
