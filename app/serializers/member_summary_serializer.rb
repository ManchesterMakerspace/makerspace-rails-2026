class MemberSummarySerializer < ActiveModel::Serializer
  attributes :id,
             :firstname,
             :lastname,
             :expirationTime,
             :email,
             :status,
             :role,
             :member_contract_signed_date,
             :member_contract_on_file,
             :totp_enabled,
             :notes,
             :household,
             :mailtrap,
             :slack,
             :checkout_approver_shop_ids,
             :checkout_approver_tool_ids,
             :resource_manager_shop_ids,
             :slack_manual_deactivation_required,
             :firebase_uid

  attribute :is_checkout_approver do
    checkout_approver.present?
  end

  attribute :checkout_approver_shop_ids do
    checkout_approver&.shop_ids || []
  end

  attribute :checkout_approver_tool_ids do
    checkout_approver&.tool_ids || []
  end

  def member_contract_on_file
    !object.member_contract_signed_date.nil?
  end

  def totp_enabled
    object.otp_required_for_login? && object.otp_secret_encrypted.present?
  end

  def household
    group = if instance_options.key?(:groups_by_name)
      instance_options[:groups_by_name][object.groupName.to_s]
    else
      object.group
    end
    return nil unless group

    {
      group_name: group.groupName,
      display_name: group.group_display_name,
      role: object.household_role,
      primary_member_name: group.groupRep,
      member_count: if instance_options.key?(:group_counts)
        instance_options[:group_counts][group.groupName.to_s].to_i
      else
        group.active_members.count
      end
    }
  end

  def mailtrap
    event = current_email_mailtrap_event
    return unknown_mailtrap_status unless event

    {
      id: event.id,
      timestamp: event.occurred_at&.in_time_zone("Eastern Time (US & Canada)")&.iso8601,
      email: event.email,
      status: event.status,
      value: event.status
    }
  end

  def current_email_mailtrap_event
    current_email = object.email.to_s.downcase
    linked_event = object.mailtrap_event
    return linked_event if linked_event&.email.to_s.downcase == current_email

    if instance_options.key?(:mailtrap_events_by_member_id_email)
      return preloaded_mailtrap_event(current_email)
    end

    MailtrapEvent.where(member_id: object.id, email: current_email).desc(:occurred_at).first
  end

  def preloaded_mailtrap_event(current_email)
    instance_options[:mailtrap_events_by_member_id_email][[object.id.to_s, current_email]]
  end

  def unknown_mailtrap_status
    {
      id: nil,
      timestamp: nil,
      email: object.email,
      status: "unknown",
      value: "No attempts made"
    }
  end

  def slack
    slack_user = object.slack_user
    return nil unless slack_user

    {
      slack_id: slack_user.slack_id,
      name: slack_user.real_name.presence || slack_user.name,
      url: ::Service::SlackConnector.slack_user_url(slack_user.slack_id)
    }
  end

  def slack_manual_deactivation_required
    object.status == "revoked" && !::Service::SlackConnector.admin_token_present?
  end

  def checkout_approver
    return @checkout_approver if defined?(@checkout_approver)

    @checkout_approver = if instance_options.key?(:checkout_approvers_by_member_id)
      instance_options[:checkout_approvers_by_member_id][object.id.to_s]
    else
      CheckoutApprover.find_by(member_id: object.id)
    end
  end
end
