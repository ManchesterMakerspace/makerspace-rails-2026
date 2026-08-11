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

  %w[is_bot deleted is_app_user].each do |flag|
    it "ignores team_join when #{flag} is true" do
      described_class.process('type' => 'team_join', 'user' => user.merge(flag => true))

      expect(SlackUser.find_by(slack_id: 'UNEWMEMBER')).to be_nil
      expect(Service::SlackConnector).not_to have_received(:send_slack_message)
    end
  end
end
