class LocationSerializer < ActiveModel::Serializer
  attributes :id, :name, :kind, :parent_id, :shop_id, :svg_element_id, :x_pct, :y_pct, :shape_points,
    :tool_names, :tool_ids

  # Which tools call this location home -- lets a map view show "what's
  # actually here" without a separate tool-listing endpoint (the existing
  # public /api/tools is scoped for the checkout-catalog use case, not this
  # one: it excludes tools the requesting member already has checked out
  # and excludes open/no-checkout tools, which would make many real tools
  # invisible on a physical map). tool_names/tool_ids are index-aligned so a
  # client can turn a displayed name into a link to that specific tool --
  # both derive from the same fetched array (not two separate queries) so
  # that alignment is guaranteed, not just coincidental ordering.
  def tool_names
    tools_cache.map(&:name)
  end

  def tool_ids
    tools_cache.map { |tool| tool.id.to_s }
  end

  private

  def tools_cache
    @tools_cache ||= object.tools.to_a
  end
end
