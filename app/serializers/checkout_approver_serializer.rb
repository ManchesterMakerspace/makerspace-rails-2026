class CheckoutApproverSerializer < ActiveModel::Serializer
  attribute(:out_of_service_tool_names) { object.tools.select(&:out_of_service).map(&:name) }
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
    object.tools.map(&:name)
  end
end
