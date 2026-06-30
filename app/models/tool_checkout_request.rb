class ToolCheckoutRequest
  include Mongoid::Document
  include ActiveModel::Serializers::JSON

  field :note, type: String
  field :status, type: String, default: 'open'
  field :message_id, type: String
  field :checked_out, type: BSON::ObjectId
  field :created_at, type: Time, default: -> { Time.now }
  field :updated_at, type: Time, default: -> { Time.now }

  belongs_to :member
  belongs_to :tool

  validates :member, presence: true
  validates :tool, presence: true
  validates :status, inclusion: { in: %w[open closed] }
  validates :note, length: { maximum: 128 }, allow_blank: true

  before_save :touch_updated_at

  def open?
    status == 'open'
  end

  def active_member?
    self.class.active_member?(member)
  end

  def valid_tool?
    tool.present?
  rescue Mongoid::Errors::DocumentNotFound
    false
  end

  def self.active_member?(member)
    member.present? && member.status == 'activeMember' && (member.expirationTime.nil? || member.expirationTime >= Time.now.to_i * 1000)
  end

  private

  def touch_updated_at
    self.updated_at = Time.now
  end
end
