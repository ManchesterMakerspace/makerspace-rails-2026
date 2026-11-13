module EventbriteIntegration
  class Synchronizer
    PUBLISHED = %w[live started ended completed].freeze
    def initialize(client = Client.new) = (@client = client)

    def refresh(resource, action: nil, received_at: nil)
      if resource['type'] == 'ticket_class'
        raise Client::Deferred.new(300 - (Time.current - received_at)) if action == 'ticket_class.deleted' && received_at && Time.current < received_at + 300
        event = event(resource.fetch('event_id'))
        return tickets(event, expected_id: action != 'ticket_class.deleted' ? resource['id'] : nil, received_at: received_at)
      end
      options = resource['type'] == 'order' ? { 'expand' => 'attendees,refund_requests' } : {}
      data = @client.get(Resource.path(resource), options)
      if received_at && Time.current < received_at + 300 &&
          ((action == 'event.unpublished' && PUBLISHED.include?(data['status'])) ||
           (action == 'event.published' && !PUBLISHED.include?(data['status'])) ||
           (action == 'order.refunded' && !refund_detected?(data)))
        raise Client::Deferred.new(30)
      end
      case resource['type']
      when 'event' then import_event(data)
      when 'order' then import_order(data)
      when 'attendee' then import_attendee(data)
      end
    rescue Client::ApiError => e
      raise Client::Deferred.new(30) if e.status == 404 && received_at && Time.current < received_at + 300
      raise
    end

    def event(id)
      known = EventbriteEvent.where(eventbrite_id: id.to_s, :organization_id.in => Configuration.organization_ids).first
      known || import_event(@client.get("events/#{id}/"))
    end

    def import_event(data)
      org = data.fetch('organization_id').to_s
      authorize!(org)
      published = PUBLISHED.include?(data['status'])
      upsert(EventbriteEvent, org, data, {
        name: data.dig('name', 'text'), starts_at: time(data.dig('start', 'utc')),
        ends_at: time(data.dig('end', 'utc')), timezone: data.dig('start', 'timezone'),
        listed: data['listed'] == true, series_parent: data['is_series'] == true,
        status: data['status'], invalidated_at: published ? nil : Time.current,
        invalidation_reason: published ? nil : data['status']
      })
    end

    def import_order(data, action: nil)
      parent = event(data.fetch('event_id'))
      refunded = refund_detected?(data)
      record = upsert(EventbriteOrder, parent.organization_id, data, {
        event_id: parent.eventbrite_id, name: data['name'], email: normalize(data['email']),
        status: data['status'], costs: money(data['costs'])
      }, refund: refunded, refund_evidence: refund_evidence(data))
      Array(data['attendees']).each { |a| import_attendee(a.merge('event_id' => parent.eventbrite_id, 'order_id' => data.fetch('id')), parent: parent) }
      record
    end

    def import_attendee(data, parent: nil)
      parent ||= event(data.fetch('event_id'))
      order_id = data['order_id'].to_s.presence
      if order_id && !EventbriteOrder.where(organization_id: parent.organization_id, eventbrite_id: order_id).exists?
        import_order(@client.get("orders/#{order_id}/", { 'expand' => 'refund_requests' }))
      end
      if data['ticket_class_id'].present? && !EventbriteTicketClass.where(organization_id: parent.organization_id, eventbrite_id: data['ticket_class_id'].to_s).exists?
        tickets(parent)
      end
      record = upsert(EventbriteAttendee, parent.organization_id, data, {
        event_id: parent.eventbrite_id, order_id: order_id, ticket_class_id: data['ticket_class_id'].to_s,
        name: data.dig('profile', 'name') || [data.dig('profile', 'first_name'), data.dig('profile', 'last_name')].compact.join(' '),
        email: normalize(data.dig('profile', 'email')), status: data['status'], refunded: data['refunded'] == true
      })
      if record.refunded && order_id
        EventbriteOrder.where(organization_id: parent.organization_id, eventbrite_id: order_id, refunded_at: nil)
          .update_all(refunded_at: Time.current, invalidated_at: Time.current, invalidation_reason: 'refund')
        EventbriteOrder.collection.find(organization_id: parent.organization_id, eventbrite_id: order_id)
          .update_one('$addToSet' => { refund_evidence: 'refunded_attendee' })
      end
      MemberLinker.link(record)
      record.reload
    end

    def tickets(parent, expected_id: nil, received_at: nil)
      Lease.with("tickets:#{parent.organization_id}:#{parent.eventbrite_id}") do |check|
        reconcile_tickets(parent, check, expected_id, received_at)
      end
    end

    private
    def reconcile_tickets(parent, check, expected_id, received_at)
      # A failed page must never invalidate the missing remainder of the list.
      seen = []
      @client.each_page("events/#{parent.eventbrite_id}/ticket_classes/") do |body, _|
        body.fetch('ticket_classes').each do |data|
          seen << data.fetch('id').to_s
          upsert(EventbriteTicketClass, parent.organization_id, data, {
            event_id: parent.eventbrite_id, name: data['name'], cost: currency(data['cost']),
            free: data['free'], quantity_total: data['quantity_total'], invalidated_at: nil, invalidation_reason: nil
          })
        end
      end
      if expected_id && !seen.include?(expected_id) && received_at && Time.current < received_at + 300
        raise Client::Deferred.new(30)
      end
      check.call
      EventbriteTicketClass.where(organization_id: parent.organization_id, event_id: parent.eventbrite_id,
        :eventbrite_id.nin => seen, invalidated_at: nil).update_all(invalidated_at: Time.current, invalidation_reason: 'deleted')
    end

    def authorize!(org)
      raise Client::ApiError.new(403, 'ORGANIZATION_NOT_ALLOWED') unless Configuration.organization_ids.include?(org)
    end
    def upsert(model, org, data, attributes, refund: false, refund_evidence: [])
      authorize!(org)
      id = data.fetch('id').to_s
      raise ArgumentError, 'Missing provider ID' if id.empty?
      Lease.with("#{model.name}:#{org}:#{id}") do |check|
        record = model.where(organization_id: org, eventbrite_id: id).first || model.new(organization_id: org, eventbrite_id: id)
        changed = time(data['changed'])
        unless changed && record.provider_changed_at && changed < record.provider_changed_at
          record.assign_attributes(attributes.merge(provider_changed_at: changed || record.provider_changed_at, synced_at: Time.current))
        end
        if refund && !record.refunded_at
          record.assign_attributes(refunded_at: Time.current, invalidated_at: Time.current, invalidation_reason: 'refund')
        end
        record.refund_evidence |= refund_evidence if model == EventbriteOrder
        check.call
        record.save!
        record
      end
    end
    def normalize(email) = email.to_s.strip.downcase.presence
    def refund_detected?(data)
      refund_evidence(data).any?
    end
    def refund_evidence(data)
      [].tap do |evidence|
        evidence << 'provider_refund_status' if data['status'].to_s.include?('refund')
        evidence << 'refunded_attendee' if Array(data['attendees']).any? { |a| a['refunded'] == true }
        evidence << 'processed_refund_request' if refund_items(data['refund_requests']).any? { |item| item['status'] == 'processed' }
      end
    end
    def time(value) = value.present? ? Time.iso8601(value) : nil
    def currency(value) = value.is_a?(Hash) ? value.slice('currency', 'value', 'major_value', 'display') : {}
    def money(value) = (value || {}).slice('base_price', 'gross', 'tax', 'eventbrite_fee', 'payment_fee').transform_values { |v| currency(v) }
    def refund_items(value)
      requests = value.is_a?(Hash) ? [value] : Array(value)
      requests.flat_map { |r| Array(r['items']) }
    end
  end
end
