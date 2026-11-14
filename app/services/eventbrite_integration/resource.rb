module EventbriteIntegration
  class Resource
    ACTIONS = {
      'event' => %w[event.created event.updated event.published event.unpublished],
      'order' => %w[order.placed order.updated order.refunded],
      'attendee' => %w[attendee.updated],
      'ticket_class' => %w[ticket_class.created ticket_class.updated ticket_class.deleted]
    }.freeze
    def self.parse(url)
      uri = URI.parse(url.to_s)
      raise ArgumentError, 'Unsupported Eventbrite resource URL' unless uri.scheme == 'https' && uri.host == 'www.eventbriteapi.com' && uri.port == 443 && !uri.userinfo && !uri.query && !uri.fragment
      id = '([A-Za-z0-9_-]+)'
      case uri.path
      when %r{\A/v3/events/#{id}/ticket_classes/#{id}/\z}
        { 'type' => 'ticket_class', 'event_id' => $1, 'id' => $2 }
      when %r{\A/v3/events/#{id}/attendees/#{id}/\z}
        { 'type' => 'attendee', 'event_id' => $1, 'id' => $2 }
      when %r{\A/v3/(events|orders|attendees)/#{id}/\z}
        { 'type' => { 'events' => 'event', 'orders' => 'order', 'attendees' => 'attendee' }.fetch($1), 'id' => $2 }
      else
        raise ArgumentError, 'Unsupported Eventbrite resource URL'
      end
    rescue URI::InvalidURIError
      raise ArgumentError, 'Unsupported Eventbrite resource URL'
    end
    def self.path(resource)
      id = resource.fetch('id')
      case resource.fetch('type')
      when 'event' then "events/#{id}/"
      when 'order' then "orders/#{id}/"
      when 'attendee' then resource['event_id'] ? "events/#{resource['event_id']}/attendees/#{id}/" : "attendees/#{id}/"
      when 'ticket_class' then "events/#{resource.fetch('event_id')}/ticket_classes/#{id}/"
      end
    end
  end
end
