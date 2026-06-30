class ToolCheckoutRequestSerializer < ActiveModel::Serializer
  attributes :id, :member_id, :member_name, :member_email, :tool_id, :tool_name,
             :shop_id, :shop_name, :note, :status, :message_id, :checked_out,
             :created_at, :updated_at

  attribute :member_name do
    object.member.try(:fullname)
  end

  attribute :member_email do
    object.member.try(:email)
  end

  attribute :tool_name do
    object.tool.try(:name)
  end

  attribute :shop_id do
    object.tool.try(:shop_id)
  end

  attribute :shop_name do
    object.tool.try(:shop).try(:name)
  end
end
