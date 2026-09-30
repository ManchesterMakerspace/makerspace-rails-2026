# Read-only, current-member data for the portal landing page.
class MemberHome
  def initialize(member)
    @member = member
  end

  def available_checkouts
    ToolCheckoutRequestEligibility.eligible_tools(member: @member)
      .reject { |tool| tool.out_of_service? || tool.shop.out_of_service? }
      .sort_by { |tool| [tool.name.casecmp?("Orientation") ? 0 : 1, tool.name.downcase, tool.id.to_s] }
      .first(10)
      .map do |tool|
        {
          id: tool.id.to_s,
          name: tool.name,
          shopName: tool.shop.name,
          requestorAnnotation: tool.effective_requestor_annotation
        }
      end
  end

  def slack
    user = @member.slack_user
    accepted = @member.provisioning_email_current? &&
      user&.slack_id.present? &&
      user.slack_email.to_s.strip.casecmp?(@member.email.to_s.strip) &&
      @member.slack_joined_at.present? && @member.slack_acceptance_pending == false

    { accepted: !!accepted, newMembersChannelUrl: accepted ? slack_channel_url : nil }
  end

  private

  def slack_channel_url
    # The initializer already resolves the workspace. Never call Slack or
    # initiate provisioning from this page, including on a cache/config miss.
    team = Service::SlackConnector.slack_team_id.to_s.strip
    channel = Service::SlackConnector.new_members_channel.to_s.strip.sub(/\A#+/, "")
    return nil if team.blank? || channel.blank?

    "https://slack.com/app_redirect?#{URI.encode_www_form(team: team, channel: channel)}"
  end
end
