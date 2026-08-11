require 'rails_helper'

RSpec.describe Service::SlackChannelAssignment do
  describe '.resolve!' do
    before do
      allow(Service::SlackConnector).to receive(:admin_client).and_return(nil)
    end

    it 'resolves normalized channel names through the cache-aware connector' do
      allow(Service::SlackConnector).to receive(:find_channel_id)
        .with('wood-shop').and_return('C12345678')

      expect(described_class.resolve!(users_channel: '  #Wood-Shop ')).to eq(
        'users_channel' => { id: 'C12345678', name: 'wood-shop' }
      )
    end

    it 'returns a descriptive validation error when Slack cannot resolve a channel' do
      allow(Service::SlackConnector).to receive(:find_channel_id).and_return(nil)

      expect do
        described_class.resolve!(announce_channel: 'missing-channel')
      end.to raise_error(
        Error::UnprocessableEntity,
        /#missing-channel could not be resolved.*bot or configured Slack admin can view it/i
      )
    end

    it 'uses an admin token to resolve a private channel invisible to the bot' do
      admin_client = double('Slack admin client')
      private_channel = double(id: 'G12345678', name: 'officers-private')
      response = double(
        channels: [private_channel],
        response_metadata: double(next_cursor: '')
      )
      allow(Service::SlackConnector).to receive(:find_channel_id)
        .with('officers-private').and_return(nil)
      allow(Service::SlackConnector).to receive(:admin_client)
        .with('conversations.list').and_return(admin_client)
      expect(admin_client).to receive(:conversations_list).with(
        types: 'public_channel,private_channel',
        exclude_archived: true,
        limit: 200,
        cursor: nil
      ).and_return(response)

      expect(described_class.resolve!(announce_channel: '#officers-private')).to eq(
        'announce_channel' => { id: 'G12345678', name: 'officers-private' }
      )
    end
  end

  describe '.invite_bot_or_notify' do
    let(:client) { double('Slack client') }
    let(:slack_user) { double(slack_id: 'UACTOR') }
    let(:actor) { double(id: BSON::ObjectId.new, slack_user: slack_user) }
    let(:channels) do
      {
        'users_channel' => { id: 'C12345678', name: 'wood-users' }
      }
    end

    before do
      allow(Service::SlackConnector).to receive(:client).and_return(client)
      allow(client).to receive(:auth_test).and_return(double(user_id: 'UBOT'))
      allow(Service::SlackConnector).to receive(:admin_client).and_return(nil)
      allow(Service::SlackConnector).to receive(:send_slack_message)
    end

    it 'first attempts to join the channel as the bot' do
      expect(client).to receive(:conversations_join).with(channel: 'C12345678')

      expect { described_class.invite_bot_or_notify(channels, actor) }.not_to raise_error
      expect(Service::SlackConnector).not_to have_received(:send_slack_message)
    end

    it 'DMs the actor rather than failing when the bot cannot be invited' do
      allow(client).to receive(:conversations_join).and_raise(StandardError, 'not allowed')

      expect { described_class.invite_bot_or_notify(channels, actor) }.not_to raise_error
      expect(Service::SlackConnector).to have_received(:send_slack_message).with(
        /could not join <#C12345678>.*manually invite <@UBOT>/i,
        'UACTOR'
      )
    end

    it 'uses an available admin token to invite the bot after join fails' do
      admin_client = double('Slack admin client')
      allow(client).to receive(:conversations_join).and_raise(StandardError, 'not in channel')
      allow(Service::SlackConnector).to receive(:admin_client)
        .with('conversations.invite').and_return(admin_client)
      expect(admin_client).to receive(:conversations_invite)
        .with(channel: 'C12345678', users: 'UBOT')

      expect { described_class.invite_bot_or_notify(channels, actor) }.not_to raise_error
      expect(Service::SlackConnector).not_to have_received(:send_slack_message)
    end
  end
end
