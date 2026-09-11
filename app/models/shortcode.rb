class Shortcode
  include Mongoid::Document
  include Mongoid::Timestamps
  store_in collection: "shortcodes"

  field :code, type: String
  field :target_url, type: String
  index({ code: 1 }, unique: true)
  index({ target_url: 1 }, unique: true)
  validates :code, format: { with: /\A[2-9A-Z]{10}\z/ }
  validates :target_url, presence: true
  validate :immutable_mapping, on: :update

  private

  def immutable_mapping
    errors.add(:base, "Shortcode mappings are permanent") if code_changed? || target_url_changed?
  end
end
