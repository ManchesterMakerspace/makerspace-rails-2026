module EventbriteIntegration
  class Presenter
    def self.call(record)
      # Explicit allowlist: never serialize raw provider payloads or internal delivery state.
      fields = %w[organization_id eventbrite_id event_id order_id ticket_class_id name email status starts_at ends_at timezone listed
        series_parent costs cost free quantity_total invalidated_at invalidation_reason refunded_at refunded member_id link_conflict synced_at]
      result = record.attributes.slice(*fields).transform_keys { |k| k.camelize(:lower) }
      result['id'] = record.id.to_s
      result['memberId'] = record.member_id.to_s if record.respond_to?(:member_id) && record.member_id
      if record.respond_to?(:event_id)
        parent = EventbriteEvent.where(organization_id: record.organization_id, eventbrite_id: record.event_id).first
        result['event'] = { name: parent.name, startsAt: parent.starts_at, timezone: parent.timezone } if parent
      end
      if record.is_a?(EventbriteOrder)
        result['memberIds'] = EventbriteAttendee.where(organization_id: record.organization_id, order_id: record.eventbrite_id).distinct(:member_id).compact.map(&:to_s)
      end
      if record.is_a?(EventbriteAttendee) && record.ticket_class_id.present?
        ticket = EventbriteTicketClass.where(organization_id: record.organization_id, eventbrite_id: record.ticket_class_id).first
        result['ticketClassName'] = ticket.name if ticket
      end
      result
    end
  end
end
