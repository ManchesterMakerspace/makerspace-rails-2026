module EventbriteIntegration
  class PublicEvents
    class InvalidFilter < StandardError; end
    FIELDS = %w[eventbrite_id name starts_at ends_at timezone summary venue_label status public_url image_url tickets_remaining].freeze

    def self.list(params, now: Time.current)
      days = integer(params.fetch(:max_days, '31'), :max_days, minimum: 1)
      minimum = integer(params[:min_tickets_remaining], :min_tickets_remaining, minimum: 0) if params.key?(:min_tickets_remaining)
      # BSON stores dates as signed 64-bit milliseconds.
      max_seconds = (2**63 - 1) / 1000 - now.to_i - 1
      raise InvalidFilter, 'max_days exceeds the supported date range.' if days * 86_400 > max_seconds
      finish = now + days * 86_400

      events = Configuration.scope_organizations(EventbriteEvent.where(listed: true, invalidated_at: nil,
        :restricted.ne => true, :series_parent.ne => true, :status.nin => %w[draft deleted],
        :starts_at.lt => finish)).any_of({ :starts_at.gte => now }, { :ends_at.gt => now })
      events = events.where(:tickets_remaining.gte => minimum) if minimum
      title = {}
      { name: '$regex', notname: '$not' }.each do |key, operator|
        next unless params.key?(key)
        value = params[key]
        raise InvalidFilter, "#{key} must be text." unless value.is_a?(String) && !value.include?("\0")
        needle = value.strip
        title[operator] = /#{Regexp.escape(needle)}/i if needle.present?
      end
      events = events.where(name: title) if title.any?
      events.only(*FIELDS).order_by(starts_at: :asc, eventbrite_id: :asc, id: :asc).map do |event|
        row = FIELDS.index_with { |field| event.public_send(field) }
        %w[public_url image_url].each { |key| row[key] = nil unless AnnouncementMessage.safe_url(row[key]) }
        row
      end
    end

    def self.integer(value, key, minimum:)
      unless value.is_a?(String) && value.match?(/\A\d{1,19}\z/) && value.to_i.between?(minimum, 2**63 - 1)
        raise InvalidFilter, "#{key} must be a whole number of at least #{minimum} within the supported range."
      end
      value.to_i
    end
    private_class_method :integer
  end
end
