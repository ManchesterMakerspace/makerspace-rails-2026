class ToolCheckoutSerializer < ActiveModel::Serializer
  attributes :id, :member_id, :tool_id, :checked_out_at, :revoked_at,
             :revocation_reason, :signed_off_via, :approved_by_id

  attribute :tool_name do
    tool.try(:name)
  end

  attribute :shop_name do
    shop.try(:name)
  end

  attribute :shop_id do
    tool.try(:shop_id)
  end

  attribute :member_name do
    member.try(:fullname)
  end

  attribute :member_email do
    member.try(:email)
  end

  attribute :approved_by_name do
    member_for(object.approved_by_id).try(:fullname)
  end

  attribute :active do
    object.active?
  end

  private

  def member
    member_for(object.member_id)
  end

  def member_for(member_id)
    return nil if member_id.blank?
    return Member.find_by(id: member_id) unless instance_options.key?(:members_by_id)

    instance_options[:members_by_id][member_id.to_s]
  end

  def tool
    return object.tool unless instance_options.key?(:tools_by_id)

    instance_options[:tools_by_id][object.tool_id.to_s]
  end

  def shop
    return tool.try(:shop) unless instance_options.key?(:shops_by_id)

    instance_options[:shops_by_id][tool.try(:shop_id).to_s]
  end
end
