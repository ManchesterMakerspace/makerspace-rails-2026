class MemberInviteJob < ApplicationJob
  include Service::GoogleDrive

  queue_as :integrations
  retry_on StandardError, wait: :polynomially_longer, attempts: 5

  def perform(member_id, provider)
    member = Member.find_by(id: member_id)
    return if member.nil? || member.status == "revoked"

    case provider
    when "google_drive"
      invite_gdrive(member.email)
    when "slack"
      Service::SlackConnector.invite_to_slack(
        member.email,
        member.lastname,
        member.firstname
      )
    else
      raise ArgumentError, "Unknown invite provider: #{provider}"
    end
  end
end
