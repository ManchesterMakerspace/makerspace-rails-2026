module EventbriteIntegration
  # One response's relationships. Member links stay authoritative in MongoDB;
  # only shared event/ticket display metadata uses the bounded Redis cache.
  class PresentationContext
    def initialize(records)
      parents = records.select { |record| record.respond_to?(:event_id) }
      @events = DisplayCache.fetch_events(parents.map { |record| [record.organization_id, record.event_id] })
      tickets = records.grep(EventbriteAttendee).select { |record| record.ticket_class_id.present? }
      @tickets = DisplayCache.fetch_ticket_classes(tickets.map { |record| [record.organization_id, record.ticket_class_id] })
      @member_ids = {}
      orders = records.grep(EventbriteOrder).map { |record| [record.organization_id, record.eventbrite_id] }.uniq
      return if orders.empty?

      selector = EventbriteAttendee.any_of(*orders.map { |org, id| { organization_id: org, order_id: id } }).selector
      EventbriteAttendee.collection.aggregate([
        { '$match' => selector },
        { '$group' => { '_id' => { 'organization_id' => '$organization_id', 'order_id' => '$order_id' },
          'member_ids' => { '$addToSet' => '$member_id' } } }
      ]).each do |row|
        pair = [row['_id']['organization_id'], row['_id']['order_id']]
        @member_ids[pair] = row['member_ids'].compact.map(&:to_s)
      end
    end

    def event(record) = @events[[record.organization_id.to_s, record.event_id.to_s]]
    def ticket(record) = @tickets[[record.organization_id.to_s, record.ticket_class_id.to_s]]
    def member_ids(record) = @member_ids.fetch([record.organization_id, record.eventbrite_id], [])
  end
end
