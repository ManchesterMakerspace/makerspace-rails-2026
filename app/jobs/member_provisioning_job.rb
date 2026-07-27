class MemberProvisioningJob < ApplicationJob
  include Service::GoogleDrive

  queue_as :integrations
  retry_on StandardError, wait: :polynomially_longer, attempts: 5

  def perform(member_id)
    member = Member.find_by(id: member_id)
    return if member.nil? || member.status == "revoked"

    provision_slack(member)
    provision_google(member)
  end

  private

  def provision_slack(member)
    Service::SlackConnector.invite_to_slack(
      member.email,
      member.lastname,
      member.firstname
    )
  rescue Error::NotAllowed
    nil
  rescue Slack::Web::Api::Errors::NotAllowedTokenType => error
    Rails.logger.warn("[MemberProvisioningJob] Slack invite skipped: #{error.message}")
  end

  def provision_google(member)
    invite_gdrive(member.email)
    invite_gdrive_writer(member.email)
  rescue Error::NotAllowed
    nil
  end
end
