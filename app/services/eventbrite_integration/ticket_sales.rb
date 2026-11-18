module EventbriteIntegration
  class TicketSales
    def self.snapshot(classes, tiers, remaining:, now: Time.current)
      {
        ticket_sales_start_at: next_sale(classes, tiers, remaining, now),
        has_member_ticket_class: classes.any? { |ticket| [ticket['name'], ticket['description']].any? { |text| text.to_s.match?(/member/i) } }
      }
    end

    def self.next_sale(classes, tiers, remaining, now)
      return if remaining == 0
      pools = tiers.index_by { |tier| tier['id'].to_s }
      by_id = classes.index_by { |ticket| ticket['id'].to_s }
      dates = []
      classes.each do |ticket|
        pool = pools[ticket['inventory_tier_id'].to_s]
        return if ticket['inventory_tier_id'].present? && !pool
        next if pool && pool['count_against_event_capacity'] == false
        next if sold_out?(ticket) || Announcements.available(ticket) == 0 || (pool && Announcements.available(pool) == 0)
        start = time(ticket['sales_start'])
        finish = time(ticket['sales_end'])
        next if finish && (finish <= now || (start && finish <= start))
        if ticket['sales_start_after'].present?
          predecessor = by_id[ticket['sales_start_after'].to_s]
          # A sell-out trigger has no predictable opening date until it fires.
          next unless predecessor && sold_out?(predecessor)
        end
        # Missing start dates mean sales start on publication. An unknown date
        # must also prevent a claim that every ticket is still awaiting sale.
        return unless start && start > now
        dates << start
      end
      dates.min
    end

    def self.sold_out?(ticket)
      ticket['on_sale_status'] == 'SOLD_OUT' ||
        (ticket['quantity_total'].is_a?(Integer) && ticket['quantity_sold'].is_a?(Integer) && ticket['quantity_sold'] >= ticket['quantity_total'])
    end

    def self.time(value)
      Time.iso8601(value) if value.present?
    rescue ArgumentError, TypeError
      nil
    end
  end
end
