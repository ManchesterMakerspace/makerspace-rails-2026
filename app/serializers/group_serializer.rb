class GroupSerializer < ActiveModel::Serializer
  attributes :id,
             :group_name,
             :group_rep,
             :expiry,
             :primary_member,
             :secondary_members,
             :size,
             :seats_used,
             :payment_accepted

  def group_name
    object.groupName
  end

  def group_rep
    object.groupRep
  end

  def payment_accepted
    object.payment_accepted?
  end

  def primary_member
    m = object.member
    return nil unless m
    member_summary(m)
  end

  def secondary_members
    object.secondary_members.map { |m| member_summary(m) }
  end

  private

  def member_summary(m)
    { id: m.id.to_s, firstname: m.firstname, lastname: m.lastname, email: m.email,
      status: m.status, expiration_time: m.expirationTime, fob_issued: m.access_cards.any? }
  end
end
