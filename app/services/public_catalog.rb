# Deliberately project only public fields. Never serialize a Mongoid document here.
class PublicCatalog
  class Unavailable < StandardError; end
  def self.shop(id)
    raise Unavailable unless BSON::ObjectId.legal?(id.to_s)
    record = Shop.where(id: id, :disabled.ne => true).only(:id, :name, :wiki_url).first
    raise Unavailable unless record
    record
  end

  def self.tool(id, public_only: true)
    raise Unavailable unless BSON::ObjectId.legal?(id.to_s)
    query = Tool.where(id: id, :disabled.ne => true)
    query = query.only(:id, :name, :description, :wiki_url, :shop_id, :open) if public_only
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

  def self.safe_url(value)
    uri = URI.parse(value.to_s)
    value if uri.is_a?(URI::HTTP) && uri.host.present?
  rescue URI::InvalidURIError
    nil
  end
end
