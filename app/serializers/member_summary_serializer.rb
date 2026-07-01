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
             :mailtrap,
             :slack,
             :checkout_approver_shop_ids,
             :firebase_uid

  attribute :is_checkout_approver do
    CheckoutApprover.exists?(member_id: object.id)
  end

  attribute :checkout_approver_shop_ids do
    CheckoutApprover.find_by(member_id: object.id)&.shop_ids || []
  end

  def member_contract_on_file
    !object.member_contract_signed_date.nil?
  end

  def totp_enabled
    object.otp_required_for_login? && object.otp_secret_encrypted.present?
  end

  def mailtrap
    event = object.mailtrap_event
    return nil unless event

    {
      id: event.id,
      timestamp: event.occurred_at&.in_time_zone("Eastern Time (US & Canada)")&.iso8601,
      email: event.email,
      status: event.status
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
end
