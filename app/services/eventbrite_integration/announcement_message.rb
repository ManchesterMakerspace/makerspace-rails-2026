module EventbriteIntegration
  class AnnouncementMessage
    def self.build(delivery, events, series_url: nil)
      events = events.sort_by { |event| [event.starts_at || Time.at(0), event.eventbrite_id] }
      first = events.first
      title = "#{delivery.kind == 'publication' ? 'New event' : 'Upcoming'}: #{first.name}"
      blocks = [{ type: 'header', text: { type: 'plain_text', text: title.first(150) } }]
      summary = ActionController::Base.helpers.strip_tags(first.summary.to_s).first(500)
      blocks << section(summary) if summary.present? && first.announcement_public?
      events.first(20).each do |event|
        zone = ActiveSupport::TimeZone[event.timezone.presence || 'America/New_York'] || ActiveSupport::TimeZone['America/New_York']
        date = event.starts_at&.in_time_zone(zone)&.strftime('%a, %b %-d at %-I:%M %p %Z') || 'Date unavailable'
        tickets = if event.tickets_sold.nil? && event.tickets_remaining.nil?
          'Ticket availability unavailable'
        else
          [event.tickets_sold.nil? ? 'Sold count unavailable' : "#{event.tickets_sold} sold",
            event.tickets_remaining.nil? ? 'Remaining count unavailable' : "#{event.tickets_remaining} remaining"].join(' · ')
        end
        sale_notice = if event.ticket_sales_start_at && event.ticket_sales_start_at > Time.current
          "Tickets go on sale #{event.ticket_sales_start_at.in_time_zone(zone).strftime('%a, %b %-d, %Y at %-I:%M %p %Z')}"
        end
        content = event.announcement_public? ? [date, event.venue_label, tickets, sale_notice].reject(&:blank?).join("\n") : "#{date}\nNo longer published — registration unavailable"
        blocks << section(content)
        url = event.announcement_public? ? registration_url(event.public_url, member_tickets: event.has_member_ticket_class) : nil
        if url
          blocks << { type: 'actions', elements: [{ type: 'button', text: { type: 'plain_text', text: 'View event / Register' }, url: url }] }
        end
      end
      blocks << section("#{events.size - 20} additional dates; view the series on Eventbrite.") if events.size > 20
      if events.size > 20 && (url = registration_url(series_url, member_tickets: events.any? { |event| event.announcement_public? && event.has_member_ticket_class }))
        blocks << { type: 'actions', elements: [{ type: 'button', text: { type: 'plain_text', text: 'View all series dates' }, url: url }] }
      end
      if first.announcement_public? && safe_url(first.image_url)
        blocks[1][:accessory] = { type: 'image', image_url: first.image_url, alt_text: first.name.to_s.first(200) } if blocks[1]&.dig(:type) == 'section'
      end
      updated = events.filter_map(&:inventory_updated_at).min
      blocks << { type: 'context', elements: [{ type: 'plain_text', text: "Inventory refreshed #{updated.utc.iso8601}" }] } if updated
      fallback = blocks.filter_map { |block| block[:text].is_a?(Hash) ? block[:text][:text] : nil }.join("\n").first(4000)
      { text: fallback.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;'), blocks: blocks }
    end

    def self.section(text) = { type: 'section', text: { type: 'plain_text', text: text.to_s.first(2900) } }
    def self.registration_url(value, member_tickets:)
      return unless safe_url(value)
      code = Configuration.member_discount_code if member_tickets
      return value unless code
      uri = URI.parse(value)
      query = URI.decode_www_form(uri.query.to_s).reject { |key, _| key == 'discount' }
      uri.query = URI.encode_www_form(query + [['discount', code]])
      uri.to_s
    end
    def self.safe_url(value)
      uri = URI.parse(value.to_s)
      %w[http https].include?(uri.scheme) && uri.host.present? && !uri.userinfo
    rescue URI::InvalidURIError
      false
    end
  end
end
