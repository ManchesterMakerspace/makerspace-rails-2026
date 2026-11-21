module EventbriteIntegration
  class Presenter
    # Explicit allowlist: never serialize raw provider payloads or internal delivery state.
    FIELDS = %w[organization_id eventbrite_id event_id order_id ticket_class_id name email status starts_at ends_at timezone listed
      series_parent costs cost free quantity_total invalidated_at invalidation_reason refunded_at refunded member_id link_conflict synced_at].freeze

    def self.many(records)
      records = records.to_a
      context = PresentationContext.new(records)
      records.map { |record| call(record, context: context) }
    end

    def self.call(record, context: nil)
      context ||= PresentationContext.new([record])
      result = record.attributes.slice(*FIELDS).transform_keys { |k| k.camelize(:lower) }
      result['id'] = record.id.to_s
      result['memberId'] = record.member_id.to_s if record.respond_to?(:member_id) && record.member_id
      if record.respond_to?(:event_id)
        parent = context.event(record)
        result['event'] = { name: parent['name'], startsAt: parent['starts_at'], timezone: parent['timezone'] } if parent
      end
      if record.is_a?(EventbriteOrder)
        result['memberIds'] = context.member_ids(record)
      end
      if record.is_a?(EventbriteAttendee) && record.ticket_class_id.present?
        ticket = context.ticket(record)
        result['ticketClassName'] = ticket['name'] if ticket
      end
      result
    end
  end
end
