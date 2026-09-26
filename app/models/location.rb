class Location
  include Mongoid::Document

  field :name, type: String
  field :kind, type: String            # free text: "cabinet", "shelf", "area", etc. -- not a fixed enum
  field :parent_id, type: BSON::ObjectId, default: nil
  field :svg_element_id, type: String, default: nil   # references a named shape in the shop's existing floor-plan SVG
  field :x_pct, type: Float, default: nil             # fallback click-placed pin, % of image width
  field :y_pct, type: Float, default: nil             # % of image height

  belongs_to :shop

  validates :name, presence: true
  validates :shop, presence: true
  validate :parent_belongs_to_same_shop

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
end
