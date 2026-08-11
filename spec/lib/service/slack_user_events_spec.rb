require 'rails_helper'

RSpec.describe Service::SlackUserEvents do
  let!(:member) { create(:member, email: 'new.member@example.com') }
  let(:user) do
    {
      'id' => 'UNEWMEMBER',
      'name' => 'newmember',
      'real_name' => 'New Member',
      'profile' => {
        'email' => 'New.Member@example.com',
        'real_name' => 'New Member'
      }
    }
  end

  before do
    allow(Service::SlackConnector).to receive(:send_slack_message)
    allow(Service::AuditLogger).to receive(:log)
    allow(ENV).to receive(:fetch).and_call_original
  end

  it 'links a new team member and sends the welcome message' do
    allow(ENV).to receive(:fetch).with('SLACK_NEW_MEMBERS_CHANNEL', 'new-members')
      .and_return('new-members-test')
    described_class.process('type' => 'team_join', 'user' => user)

    expect(SlackUser.find_by(slack_id: 'UNEWMEMBER')).to have_attributes(
      member_id: member.id,
      slack_email: 'new.member@example.com',
      name: 'newmember',
      real_name: 'New Member'
    )
    expect(Service::SlackConnector).to have_received(:send_slack_message)
      .with(/Welcome to the makerspace New Member! \(<@UNEWMEMBER>\)/, 'new-members-test')
  end

  it 'updates profile details without welcoming for user_change' do
    SlackUser.create!(member: member, slack_id: 'UNEWMEMBER', slack_email: 'old@example.com')

    described_class.process('type' => 'user_change', 'user' => user.merge('name' => 'new-name'))

    expect(SlackUser.find_by(slack_id: 'UNEWMEMBER')).to have_attributes(
      slack_email: 'new.member@example.com',
      name: 'new-name'
    )
    expect(Service::SlackConnector).not_to have_received(:send_slack_message)
  end

  it 'audits a changed Slack email without relinking or changing the Member email' do
    allow(Service::AuditLogger).to receive(:log).and_call_original
    other_member = create(:member, email: 'changed@example.com')
    SlackUser.create!(member: member, slack_id: 'UNEWMEMBER', slack_email: member.email)
    changed_user = user.merge('profile' => user['profile'].merge('email' => other_member.email))

    described_class.process(
      { 'type' => 'user_change', 'user' => changed_user },
      event_id: 'Ev-email-change'
    )

    expect(member.reload.email).to eq('new.member@example.com')
    expect(SlackUser.find_by(slack_id: 'UNEWMEMBER')).to have_attributes(
      member_id: member.id,
      slack_email: 'changed@example.com'
    )
    expect(Service::AuditLogger).to have_received(:log).with(
      hash_including(
        event_type: 'slack_email_mismatch',
        resource_id: member.id,
        subject: member,
        field_changes: {
          'slack_email' => ['new.member@example.com', 'changed@example.com']
        },
        slack_channel: Service::SlackConnector.logs_channel,
        message_details: /admin must reconcile.*Ev-email-change/i
      )
    )
    expect(AuditLog.where(event_type: 'slack_email_mismatch', resource_id: member.id).count).to eq(1)
    expect(Service::SlackConnector).to have_received(:send_slack_message).with(
      /admin must reconcile.*Member email and Slack email/i,
      Service::SlackConnector.logs_channel
    )
  end

  it 'invalidates a deleted Slack user in place and hides the inactive link' do
    existing = SlackUser.create!(
      member: member,
      slack_id: 'UNEWMEMBER',
      slack_email: 'new.member@example.com'
    )

    described_class.process(
      { 'type' => 'user_change', 'user' => user.merge('deleted' => true) },
      event_id: 'Ev-deleted'
    )

    expect(SlackUser.find_by(slack_id: 'UNEWMEMBER')).to be_nil
    expect(member.reload.slack_user).to be_nil
    expect(SlackUser.unscoped.find(existing.id)).to have_attributes(
      member_id: member.id,
      slack_id: 'UNEWMEMBER',
      slack_email: 'new.member@example.com',
      invalidation_reason: 'slack_user_deleted; event_id=Ev-deleted'
    )
    expect(SlackUser.unscoped.find(existing.id).invalidated_at).to be_present
    expect(Service::SlackConnector).not_to have_received(:send_slack_message)
  end

  %w[is_bot is_app_user].each do |flag|
    it "ignores team_join when #{flag} is true" do
      described_class.process('type' => 'team_join', 'user' => user.merge(flag => true))

      expect(SlackUser.find_by(slack_id: 'UNEWMEMBER')).to be_nil
      expect(Service::SlackConnector).not_to have_received(:send_slack_message)
    end
  end
end
