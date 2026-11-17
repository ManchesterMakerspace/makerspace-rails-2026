require 'uri'
module EventbriteIntegration
  class Configuration
    def self.organization_ids = ENV.fetch('EVENTBRITE_ORGANIZATION_IDS', '').split(',').map(&:strip).reject(&:empty?).uniq
    def self.token = ENV['EVENTBRITE_API_KEY'].to_s.strip
    def self.member_discount_code = ENV['EVENTBRITE_MEMBER_DISCOUNT_CODE'].to_s.strip.presence
    def self.webhook_path = ENV['EVENTBRITE_WEBHOOK_PATH'].to_s.strip
    def self.validate!
      raise ArgumentError, 'Eventbrite API token is required' if token.empty?
      raise ArgumentError, 'Invalid Eventbrite organization ID' unless organization_ids.all? { |id| id.match?(/\A[a-zA-Z0-9_-]+\z/) }
    end
    def self.organization_allowed?(id)
      id.present? && (organization_ids.empty? || organization_ids.include?(id))
    end
    def self.scope_organizations(scope)
      organization_ids.empty? ? scope : scope.where(:organization_id.in => organization_ids)
    end
    def self.validate_path!
      return false if webhook_path.empty?
      unless valid_webhook_path?
        Rails.logger.warn('Eventbrite webhook disabled: EVENTBRITE_WEBHOOK_PATH requires a private path starting with /, without a trailing / or reserved prefix, and ending in at least 32 random URL-safe characters')
        return false
      end
      validate!
      true
    end
    def self.valid_webhook_path?
      webhook_path.match?(%r{\A/(?:[a-zA-Z0-9_-]+/)*[a-zA-Z0-9_-]{32,}\z}) &&
        !webhook_path.match?(%r{\A/(api|assets|billing|slack|members|rails)(/|$)})
    end
  end
end
