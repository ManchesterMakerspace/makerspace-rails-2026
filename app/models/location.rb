class Location
  include Mongoid::Document

  field :name, type: String
  field :kind, type: String            # free text: "cabinet", "shelf", "area", etc. -- not a fixed enum
  field :parent_id, type: BSON::ObjectId, default: nil
  field :svg_element_id, type: String, default: nil   # references a named shape in the shop's existing floor-plan SVG
  field :x_pct, type: Float, default: nil             # fallback click-placed pin, % of image width
  field :y_pct, type: Float, default: nil             # % of image height
  field :shape_points, type: Array, default: nil      # admin-drawn polygon: [{x:, y:}, ...], % of image

  belongs_to :shop

  validates :name, presence: true
  validates :shop, presence: true
  validates :x_pct, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }, allow_nil: true
  validates :y_pct, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }, allow_nil: true
  validate :parent_belongs_to_same_shop
  validate :parent_is_not_a_descendant
  validate :shape_points_form_a_polygon
  validate :shape_points_within_bounds

  index({ shop_id: 1 })
  index({ parent_id: 1 })

  def parent
    Location.find(parent_id) if parent_id
  end

  def children
    Location.where(parent_id: id)
  end

  private

  def parent_belongs_to_same_shop
    return unless parent_id
    parent_location = Location.where(id: parent_id).first
    errors.add(:parent_id, "must belong to the same shop") if parent_location && parent_location.shop_id != shop_id
  end

  # Only relevant when re-parenting an existing location -- a brand new
  # record can't already be an ancestor of anything. Walks up the chain with
  # a visited-set guard so a pre-existing cycle in the data can't hang this
  # in an infinite loop.
  def parent_is_not_a_descendant
    return unless parent_id && persisted?
    visited = Set.new
    ancestor = Location.where(id: parent_id).first
    while ancestor
      if ancestor.id == id || visited.include?(ancestor.id)
        errors.add(:parent_id, "cannot be a descendant of this location")
        return
      end
      visited << ancestor.id
      ancestor = ancestor.parent_id ? Location.where(id: ancestor.parent_id).first : nil
    end
  end

  def shape_points_form_a_polygon
    return if shape_points.nil?
    errors.add(:shape_points, "must have at least 3 points to form a shape") if shape_points.size < 3
  end

  def shape_points_within_bounds
    return if shape_points.nil?
    out_of_bounds = shape_points.any? do |point|
      point = point.to_h
      x, y = point[:x] || point["x"], point[:y] || point["y"]
      x.nil? || y.nil? || x.to_f < 0 || x.to_f > 100 || y.to_f < 0 || y.to_f > 100
    end
    errors.add(:shape_points, "must have x/y values between 0 and 100") if out_of_bounds
  end
end
