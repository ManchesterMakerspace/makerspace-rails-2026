class Tool
  include Mongoid::Document
  include ActiveModel::Serializers::JSON

  field :name, type: String
  field :description, type: String
  field :disabled, type: Boolean, default: false
  field :announce, type: Boolean, default: false
  field :announce_channel, type: String
  # Optional prerequisite tool IDs — UI warns if member hasn't been checked out on these
  field :prerequisite_ids, type: Array, default: []

  belongs_to :shop

  validates :name, presence: true
  validates :shop, presence: true

  def announce?
    announce == true
  end

  # Human-readable prerequisite names for display
  def prerequisites
    prerequisite_ids.present? ? Tool.where(:id.in => prerequisite_ids) : []
  end
end
