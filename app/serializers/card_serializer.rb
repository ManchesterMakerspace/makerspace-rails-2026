class CardSerializer < ActiveModel::Serializer
  attributes :id, :holder, :expiry, :validity, :uid
  belongs_to :member

  def uid
    return object.uid if scope&.role.in?(['admin', 'board_member'])

    object.id.to_s
  end
end
