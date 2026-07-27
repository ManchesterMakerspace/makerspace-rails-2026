class ToolCheckoutRequestSerializer < ActiveModel::Serializer
  attributes :id, :member_id, :member_name, :member_email, :tool_id, :tool_name,
             :shop_id, :shop_name, :note, :request_date, :status, :message_id,
             :checked_out_id, :member_slack_url

  def member_name
    member.try(:fullname)
  end

  def member_email
    member.try(:email)
  end

  def member_slack_url
    slack_user = if instance_options.key?(:slack_users_by_member_id)
      instance_options[:slack_users_by_member_id][object.member_id.to_s]
    else
      member.try(:slack_user)
    end
    return nil unless slack_user
    ::Service::SlackConnector.slack_user_url(slack_user.slack_id)
  end

  def tool_name
    tool.try(:name)
  end

  def shop_id
    tool.try(:shop_id)
  end

  def shop_name
    shop.try(:name)
  end

  private

  def member
    return object.member unless instance_options.key?(:members_by_id)

    instance_options[:members_by_id][object.member_id.to_s]
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
