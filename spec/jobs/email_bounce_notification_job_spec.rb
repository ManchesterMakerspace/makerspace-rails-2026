require 'rails_helper'

RSpec.describe EmailBounceNotificationJob do
  let(:member) { create(:member) }
  let(:event_name) { "bounce" }
  let!(:event) do
    create(:mailtrap_event, member: member, email: member.email, status: event_name, event: event_name,
                            response: "550 5.1.1 mailbox does not exist")
  end

  before do
    allow(::Service::SlackConnector).to receive(:send_slack_message)
  end

  def run_job
    described_class.perform_now(event.id.to_s)
  end

  def sent_to(target)
    expect(::Service::SlackConnector).to have_received(:send_slack_message).with(anything, target, source: "email bounce")
  end

  it "messages the member and tells the board they were told" do
    SlackUser.create!(member_id: member.id, slack_email: member.email, slack_id: "U123")

    run_job

    sent_to("U123")
    expect(::Service::SlackConnector).to have_received(:send_slack_message)
      .with(a_string_including("mailbox does not exist", "They were sent a Slack message"),
            ::Service::SlackConnector.members_relations_channel, source: "email bounce")
  end

  it "tells the board the member was not told when they have no Slack link" do
    run_job

    expect(::Service::SlackConnector).to have_received(:send_slack_message)
      .with(a_string_including("have not been told"), ::Service::SlackConnector.members_relations_channel,
            source: "email bounce")
    expect(::Service::SlackConnector).not_to have_received(:send_slack_message).with(anything, "U123", anything)
  end

  context "when Mailtrap suspended the address" do
    let(:event_name) { "suspension" }

    it "alerts the board but does not ask the member to change their email" do
      SlackUser.create!(member_id: member.id, slack_email: member.email, slack_id: "U123")

      run_job

      expect(::Service::SlackConnector).to have_received(:send_slack_message).once
      expect(::Service::SlackConnector).to have_received(:send_slack_message)
        .with(a_string_including("The member was not messaged"), ::Service::SlackConnector.members_relations_channel,
              source: "email bounce")
    end
  end

  it "does nothing once the member has changed to a different address" do
    member.set(email: "new-address@example.com")

    run_job

    expect(::Service::SlackConnector).not_to have_received(:send_slack_message)
  end

  it "does nothing for a revoked member" do
    member.set(status: "revoked")

    run_job

    expect(::Service::SlackConnector).not_to have_received(:send_slack_message)
  end
end
