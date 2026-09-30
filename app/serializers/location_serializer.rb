class LocationSerializer < ActiveModel::Serializer
  attributes :id, :name, :kind, :parent_id, :shop_id, :svg_element_id, :x_pct, :y_pct, :shape_points,
    :tool_names

  # Which tools call this location home -- lets a map view show "what's
  # actually here" without a separate tool-listing endpoint (the existing
  # public /api/tools is scoped for the checkout-catalog use case, not this
  # one: it excludes tools the requesting member already has checked out
  # and excludes open/no-checkout tools, which would make many real tools
  # invisible on a physical map).
  def tool_names
    object.tools.pluck(:name)
  end
end
