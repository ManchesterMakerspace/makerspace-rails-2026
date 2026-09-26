class LocationSerializer < ActiveModel::Serializer
  attributes :id, :name, :kind, :parent_id, :shop_id, :svg_element_id, :x_pct, :y_pct, :shape_points
end
