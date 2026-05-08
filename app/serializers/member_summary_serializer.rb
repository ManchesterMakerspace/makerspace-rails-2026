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
             :notes,
             :mailtrap,
             :slack,
             :firebase_uid

  def member_contract_on_file
    !object.member_contract_signed_date.nil?
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
    slack_user = SlackUser.find_by(member_id: object.id)
    return nil unless slack_user

    {
      slack_id: slack_user.slack_id,
      name: slack_user.real_name.presence || slack_user.name
    }
  end
end
