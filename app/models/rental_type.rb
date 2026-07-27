class RentalType
  include Mongoid::Document
  include Mongoid::Search
  include ActiveModel::Serializers::JSON

  field :display_name,       type: String   # e.g. "Storage Tote"
  field :active,             type: Boolean, default: true
  field :invoice_option_id,  type: String   # references InvoiceOption._id

  search_in :display_name

  validates :display_name, presence: true, uniqueness: true

  index({ active: 1, display_name: 1 })
  after_save { MongoCache.invalidate("rental_types") }
  after_destroy { MongoCache.invalidate("rental_types") }

  def invoice_option
    return nil if invoice_option_id.blank?
    InvoiceOption.find(invoice_option_id)
  rescue
    nil
  end

  def self.search(searchTerms, criteria = Mongoid::Criteria.new(RentalType))
    criteria.full_text_search(searchTerms)
  end
end
