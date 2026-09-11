# Deliberately project only public fields. Never serialize a Mongoid document here.
class PublicCatalog
  class Unavailable < StandardError; end
  def self.shop(id)
    raise Unavailable unless BSON::ObjectId.legal?(id.to_s)
    record = Shop.where(id: id, :disabled.ne => true).only(:id, :name, :wiki_url, :google_resource_id, :resource_email).first
    raise Unavailable unless record
    record
  end

  def self.tool(id, public_only: true)
    raise Unavailable unless BSON::ObjectId.legal?(id.to_s)
    query = Tool.where(id: id, :disabled.ne => true)
    query = query.only(:id, :name, :description, :wiki_url, :shop_id, :open, :google_resource_id, :resource_email) if public_only
    record = query.first
    raise Unavailable unless record
    [record, shop(record.shop_id)]
  end

  def self.shop_fields(shop)
    { id: shop.id.to_s, name: shop.name, wiki_url: safe_url(shop.effective_wiki_url) }
  end

  def self.tool_fields(tool, shop)
    { id: tool.id.to_s, name: tool.name, description: tool.description,
      open: tool.open, wiki_url: safe_url(tool.wiki_url.presence || WikiUrlBuilder.tool_url(shop.name, tool.name)),
      shop: shop_fields(shop) }
  end

  def self.calendar_fields(record)
    resource_id = record.google_resource_id.to_s.strip
    address = record.resource_email.to_s.strip
    if address.blank?
      return nil if resource_id.blank?

      # Legacy records may have only a calendar ID or full calendar address.
      address = resource_id.end_with?("@resource.calendar.google.com") ? resource_id : "#{resource_id}@resource.calendar.google.com"
    end
    { name: record.name, url: "https://calendar.google.com/calendar/embed?#{URI.encode_www_form(src: address)}" }
  end

  def self.footer_links
    [
      { label: "Public Home", icon: "home", url: "https://manchestermakerspace.org/" },
      { label: "Public Wiki", icon: "help_center", url: safe_url(WikiUrlBuilder.base_url) },
      { label: "Event Calendar", icon: "calendar_month", url: "https://manchestermakerspace.org/calendar" },
      { label: "Chat with us on Slack", icon: "chat", url: "https://manchestermakerspace.slack.com/archives/C29L2UMDF" },
      { label: "Contact us via Email", icon: "mail", url: "mailto:#{ENV.fetch('SMTP_FROM', 'contact@manchestermakerspace.org')}?subject=Member%20Portal%20assistance%20request" }
    ].select { |link| link[:url].present? }
  end

  def self.safe_url(value)
    uri = URI.parse(value.to_s)
    value if uri.is_a?(URI::HTTP) && uri.host.present?
  rescue URI::InvalidURIError
    nil
  end
end
