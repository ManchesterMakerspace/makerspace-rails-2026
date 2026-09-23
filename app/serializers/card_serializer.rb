class CardSerializer < ActiveModel::Serializer
  attributes :id, :holder, :expiry, :validity, :uid, :member_id
  belongs_to :member
end
