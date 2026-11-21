module EventbriteIntegration
  class Announcements
    def initialize(client = Client.new)
      @client = client
      @sync = Synchronizer.new(client)
    end

    def hydrate(id)
      event = @sync.import_event(@client.get("events/#{id}/", 'expand' => 'venue,logo'))
      # Availability changes must reach saved messages even if inventory fails next.
      dirty_event(event)
      event
    end

    def webhook(resource, action, received_at: nil)
      return if action.blank?
      id = if resource['type'] == 'event'
        resource['id']
      elsif resource['event_id']
        resource['event_id']
      else
        model = resource['type'] == 'order' ? EventbriteOrder : EventbriteAttendee
        Configuration.scope_organizations(model.where(eventbrite_id: resource['id'])).first&.event_id
      end
      return unless id
      event = hydrate(id)
      if resource['type'] == 'order'
        event.set(inventory_refresh_at: 5.minutes.from_now)
      end
      return unless event.announcement_public?
      occurrences = event.series_parent || (action == 'event.published' && event.series_id.present?) ? series(event) : [event]
      first = first_upcoming(occurrences) if action == 'event.published'
      if action == 'event.published' && first.nil? && received_at && Time.current < received_at + 300
        # Publishing a series can precede visibility of its occurrences in the API.
        raise Client::Deferred.new(30)
      end
      # Full event details are sufficient for the initial announcement. Persist
      # it before inventory requests so a ticket endpoint outage cannot lose it.
      request(first, 'publication', [first.eventbrite_id]) if first
      # A long-running series can contain years of historical occurrences. Only
      # inventory represented by our messages (or the new announcement) is needed.
      targets = if event.series_parent
        represented = deliveries(event).pluck(:event_ids).flatten
        occurrences.select { |item| represented.include?(item.eventbrite_id) }
      else
        [event]
      end
      ([first] + targets).compact.uniq(&:id).each { |item| refresh(item) }
    end

    def series(event)
      hydrate(event.announcement_scope) unless event.series_parent
      result = []
      @client.each_page("series/#{event.announcement_scope}/events/", { 'order_by' => 'start_asc' }) do |body, _|
        body.fetch('events').each do |data|
          raise Client::ApiError.new(403, 'ORGANIZATION_MISMATCH') unless data['organization_id'].to_s == event.organization_id
          item = @sync.import_event(data)
          dirty_event(item)
          result << item
        end
      end
      result
    end

    def refresh(event)
      Lease.with("inventory:#{event.organization_id}:#{event.eventbrite_id}") do |check|
        fresh = hydrate(event.eventbrite_id)
        return fresh unless fresh.announcement_public?
        classes = []
        @client.each_page("events/#{event.eventbrite_id}/ticket_classes/") { |body, _| classes.concat(body.fetch('ticket_classes')) }
        tiers = []
        if classes.any? { |ticket| ticket['inventory_tier_id'].present? }
          body = @client.get("events/#{event.eventbrite_id}/inventory_tiers/")
          if body.key?('pagination')
            @client.each_page("events/#{event.eventbrite_id}/inventory_tiers/") { |page, _| tiers.concat(page.fetch('inventory_tiers')) }
          else
            tiers = body.fetch('inventory_tiers')
          end
        end
        sold, remaining = self.class.totals(classes, tiers, fresh.capacity)
        sales = TicketSales.snapshot(classes, tiers, remaining: remaining)
        check.call
        fresh.set(sales.merge(tickets_sold: sold, tickets_remaining: remaining, inventory_updated_at: Time.current))
        dirty_event(fresh)
        fresh
      end
    end

    # Inventory tiers share capacity between classes; never sum each class's pool.
    def self.totals(classes, tiers, capacity)
      by_id = tiers.index_by { |tier| tier['id'].to_s }
      return [nil, nil] if classes.any? { |ticket| ticket['inventory_tier_id'].present? && !by_id.key?(ticket['inventory_tier_id'].to_s) }
      admission = classes.reject { |ticket| ticket['inventory_tier_id'].present? && by_id.fetch(ticket['inventory_tier_id'].to_s)['count_against_event_capacity'] == false }
      return [nil, nil] if admission.empty? || admission.any? { |ticket| !ticket['quantity_sold'].is_a?(Integer) || ticket['quantity_sold'] < 0 }
      sold = admission.sum { |ticket| ticket['quantity_sold'] }
      pending = 0
      pools = admission.group_by { |ticket| ticket['inventory_tier_id'].presence || "class:#{ticket.fetch('id')}" }.map do |key, tickets|
        pool = by_id[key.to_s] || tickets.first
        available = self.available(pool)
        next unless available
        pending += pool.fetch('quantity_pending', 0)
        # Shared capacity does not override a smaller aggregate ticket-class limit.
        class_limits = tickets.map { |ticket| self.available(ticket) }
        available = [available, class_limits.sum].min if class_limits.none?(&:nil?)
        available
      end
      return [sold, nil] if pools.any?(&:nil?)
      remaining = pools.sum
      remaining = [remaining, [capacity - sold - pending, 0].max].min if capacity
      [sold, remaining]
    end

    def self.available(pool)
      values = [pool['quantity_total'], pool['quantity_sold'], pool.fetch('quantity_pending', 0)]
      return unless values.all? { |value| value.is_a?(Integer) && value >= 0 }
      [values[0] - values[1] - values[2], 0].max
    end

    def request(event, kind, ids, day: '')
      key = { organization_id: event.organization_id, scope_id: event.announcement_scope,
        kind: kind, day: day, mode: Service::SlackConnector.message_destination_mode }
      Lease.with("announcement:#{key.values.join(':')}") do |check|
        delivery = EventbriteSlackDelivery.where(key).first || EventbriteSlackDelivery.new(key)
        # Use the sender's lease as well: its persisted receipt determines whether
        # a publication can still be retargeted to a different first occurrence.
        Lease.with("slack-delivery:#{delivery.id}") do |delivery_check|
          delivery.reload if delivery.persisted?
          delivery.event_ids = if kind == 'publication'
            delivery.ts.present? || delivery.sending_at.present? ? delivery.event_ids : ids
          else
            delivery.event_ids | ids
          end
          check.call
          delivery_check.call
          delivery.expired = false
          delivery.save!
          dirty(delivery)
          delivery.reload
        end
      end
    end

    def upcoming(days)
      raise ArgumentError, 'days must be a positive whole number' unless days.to_s.match?(/\A[1-9][0-9]*\z/)
      start = Time.current
      finish = start + days.to_i * 86_400
      orgs = Configuration.organization_ids
      if orgs.empty?
        @client.each_page('users/me/organizations/') { |body, _| orgs.concat(body.fetch('organizations').map { |org| org.fetch('id').to_s }) }
      end
      events = []
      orgs.uniq.each do |org|
        @client.each_page("organizations/#{org}/events/", { 'time_filter' => 'current_future', 'show_series_parent' => 'false' }) do |body, _|
          body.fetch('events').each do |data|
            event = @sync.import_event(data)
            events.concat(event.series_parent ? series(event) : [event])
          end
        end
      end
      candidates = events.uniq(&:id).select { |event| event.announcement_upcoming? && event.starts_at >= start && event.starts_at < finish }
      candidates = candidates.map { |event| refresh(event) }.select { |event| event.announcement_upcoming? && event.starts_at >= start && event.starts_at < finish }
      candidates.select { |event| event.series_id.present? }.uniq { |event| [event.organization_id, event.series_id] }.each { |event| hydrate(event.series_id) }
      candidates.group_by { |event| [event.organization_id, event.announcement_scope] }.map do |_, group|
        request(group.first, 'reminder', group.map(&:eventbrite_id), day: start.in_time_zone('America/New_York').to_date.iso8601)
      end
    end

    private
    def first_upcoming(occurrences)
      candidates = occurrences.select(&:announcement_upcoming?).index_by(&:id)
      hydrated = {}
      loop do
        first = candidates.values.min_by { |item| [item.starts_at, item.eventbrite_id] }
        return first if first.nil? || hydrated[first.id]
        fresh = hydrate(first.eventbrite_id)
        hydrated[first.id] = true
        # Re-sort after hydration; the earliest listed date may now be canceled
        # or rescheduled behind another occurrence.
        if fresh.announcement_upcoming?
          candidates[first.id] = fresh
        else
          candidates.delete(first.id)
        end
      end
    end

    def deliveries(event) = EventbriteSlackDelivery.where(organization_id: event.organization_id, scope_id: event.announcement_scope)
    def dirty_event(event)
      scope = event.series_parent ? deliveries(event) : EventbriteSlackDelivery.where(organization_id: event.organization_id, event_ids: event.eventbrite_id)
      scope.collection.find(scope.selector).update_many('$inc' => { 'revision' => 1 })
      now = Time.current
      scope.where(failed_at: nil).where('$or' => [{ due_at: nil }, { due_at: { '$lte' => now } }]).update_all(due_at: now)
    end
    def dirty(delivery)
      delivery.inc(revision: 1)
      # New data must not bypass a Slack Retry-After/backoff already in progress.
      EventbriteSlackDelivery.where(id: delivery.id, failed_at: nil)
        .where('$or' => [{ due_at: nil }, { due_at: { '$lte' => Time.current } }]).update_all(due_at: Time.current)
    end
  end
end
