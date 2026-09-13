class CheckoutApproverSerializer < ActiveModel::Serializer
  attribute(:out_of_service_tool_names) { loaded_tools.select(&:out_of_service).map(&:name) }
  attribute :tools do
    loaded_tools.map { |tool| { id: tool.id.to_s, name: tool.name, shopId: tool.shop_id.to_s, outOfService: !!tool.out_of_service } }
  end
  attributes :id, :member_id, :shop_ids, :tool_ids

  attribute :member_name do
    object.member.try(:fullname)
  end

  attribute :member_email do
    object.member.try(:email)
  end

  attribute :shop_names do
    object.shops.map(&:name)
  end

  attribute :tool_names do
    loaded_tools.map(&:name)
  end

  def loaded_tools = @loaded_tools ||= object.tools.to_a
end
