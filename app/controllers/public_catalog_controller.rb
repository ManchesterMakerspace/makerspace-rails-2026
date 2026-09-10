# No ApplicationController callbacks, authentication, session, or CSRF helpers.
class PublicCatalogController < ActionController::Base
  include CatalogUnavailable
  TEMPLATE_VERSION = "public-catalog-v1"

  def shop
    shop = PublicCatalog.shop(params[:id])
    tools = Tool.where(shop_id: shop.id, :disabled.ne => true)
      .only(:id, :name, :open).collation(locale: "en", strength: 2).order_by(name: :asc, id: :asc)
    projection = PublicCatalog.shop_fields(shop).merge(tools: tools.map do |tool|
      { id: tool.id.to_s, name: tool.name, open: tool.open }
    end)
    serve(projection, "shop")
  end

  def tool
    tool, shop = PublicCatalog.tool(params[:id])
    serve(PublicCatalog.tool_fields(tool, shop), "tool")
  end

  private

  def serve(projection, kind)
    raise PublicCatalog::Unavailable unless request.format.html? || request.format.json?
    digest = Digest::SHA256.hexdigest([TEMPLATE_VERSION, kind, request.format.to_s, projection.to_json].join("\n"))
    response.set_header("Cache-Control", "public, max-age=259200, s-maxage=259200")
    response.set_header("ETag", %Q("#{digest}"))
    return head(:not_modified) if request.fresh?(response)
    return render(json: projection) if request.format.json?

    renderer = -> { render_to_string(template: "public_catalog/#{kind}", layout: "public_catalog", locals: { page: projection }) }
    html = begin
      Rails.cache.fetch("public-catalog/#{digest}", expires_in: 30.minutes) { renderer.call }
    rescue StandardError => error
      Rails.logger.warn("Public catalog cache unavailable: #{error.class}")
      renderer.call
    end
    render html: html.html_safe, layout: false
  end
end
