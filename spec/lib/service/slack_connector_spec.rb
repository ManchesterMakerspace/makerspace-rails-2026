require 'rails_helper'

RSpec.describe Service::SlackConnector do
  describe '.invite_to_slack' do
    before do
      allow(ENV).to receive(:[]).and_call_original
    end

    it 'treats a missing admin token as disabled even when invites are enabled' do
      allow(ENV).to receive(:[]).with('SLACK_INVITES_ENABLED').and_return('true')
      allow(ENV).to receive(:[]).with('SLACK_ADMIN_TOKEN').and_return(nil)

      expect(Slack::Web::Client).not_to receive(:new)

      expect do
        described_class.invite_to_slack('new.member@example.com', 'Member', 'New')
      end.to raise_error(Error::NotAllowed, 'Slack invites are not enabled in this environment')
    end

    it 'does not invite when the feature flag is disabled' do
      allow(ENV).to receive(:[]).with('SLACK_INVITES_ENABLED').and_return('false')
      allow(ENV).to receive(:[]).with('SLACK_ADMIN_TOKEN').and_return('admin-token')

      expect(Slack::Web::Client).not_to receive(:new)

      expect do
        described_class.invite_to_slack('new.member@example.com', 'Member', 'New')
      end.to raise_error(Error::NotAllowed)
    end

    it 'invites when both the feature flag and admin token are configured' do
      allow(ENV).to receive(:[]).with('SLACK_INVITES_ENABLED').and_return('true')
      allow(ENV).to receive(:[]).with('SLACK_ADMIN_TOKEN').and_return('admin-token')

      client = instance_double(Slack::Web::Client)
      allow(Slack::Web::Client).to receive(:new).with(token: 'admin-token').and_return(client)
      allow(client).to receive(:users_admin_invite)

      described_class.invite_to_slack('new.member@example.com', 'Member', 'New')

      expect(client).to have_received(:users_admin_invite).with(
        email: 'new.member@example.com',
        first_name: 'New',
        last_name: 'Member'
      )
    end
  end
end
