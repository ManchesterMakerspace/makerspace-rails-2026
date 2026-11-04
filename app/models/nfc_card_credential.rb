class NfcCardCredential
  include Mongoid::Document
  field :memberId, type: BSON::ObjectId
  field :uid, type: String
  field :state, type: String
  field :sealed, type: Hash
  field :createdAt, type: Time
  field :enrolledAt, type: Time
  field :enrolledByMemberId, type: BSON::ObjectId
  field :enrollmentSource, type: String
end
