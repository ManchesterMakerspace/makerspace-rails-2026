class PendingDocumentUpload
  include Mongoid::Document
  include Mongoid::Timestamps::Created

  MAX_BYTES = 2.megabytes

  field :document_type, type: String
  field :resource_type, type: String
  field :resource_id, type: BSON::ObjectId
  field :data, type: BSON::Binary
  field :expires_at, type: Time

  index({ expires_at: 1 }, { expire_after_seconds: 0 })
  index({ resource_type: 1, resource_id: 1 })

  validates :document_type, :resource_type, :resource_id, :data, :expires_at, presence: true
  validate :payload_is_bounded

  def self.stage!(base64_data:, document_type:, resource:)
    decoded = Base64.strict_decode64(base64_data)
    create!(
      document_type: document_type,
      resource_type: resource.class.name,
      resource_id: resource.id,
      data: BSON::Binary.new(decoded),
      expires_at: 24.hours.from_now
    )
  rescue ArgumentError, TypeError
    raise Error::UnprocessableEntity.new("Invalid signature data")
  end

  def base64_data
    Base64.strict_encode64(data.data)
  end

  private

  def payload_is_bounded
    return if data.nil? || data.data.bytesize <= MAX_BYTES

    errors.add(:data, "must be 2 MB or smaller")
  end
end
