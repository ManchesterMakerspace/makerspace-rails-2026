class CheckoutApproverSerializer < ActiveModel::Serializer
  attributes :id, :member_id, :shop_ids, :tool_ids

  attribute :member_name do
    (checkout_context ? checkout_context.members[object.member_id.to_s] : object.member).try(:fullname)
  end

  attribute :member_email do
    (checkout_context ? checkout_context.members[object.member_id.to_s] : object.member).try(:email)
  end

  attribute :shop_names do
    checkout_context ? checkout_context.shop_names(object.shop_ids) : object.shops.map(&:name)
  end

  attribute :tool_names do
    checkout_context ? checkout_context.names(object.tool_ids) : object.tools.map(&:name)
  end

  def checkout_context
    instance_options[:checkout_context]
  end
end
