require 'rails_helper'

RSpec.describe Service::SlackChannelAssignment do
  describe '.resolve!' do
    before do
      allow(Service::SlackConnector).to receive(:admin_client).and_return(nil)
    end

    it 'resolves normalized channel names through the cache-aware connector' do
      allow(Service::SlackConnector).to receive(:find_channel_id)
        .with('#wood-shop').and_return('C12345678')

      expect(described_class.resolve!(users_channel: '  #Wood-Shop ')).to eq(
        'users_channel' => { id: 'C12345678', name: '#wood-shop' }
      )
    end

    it 'fails open instead of raising when Slack cannot resolve a channel, and does not save it' do
      allow(Service::SlackConnector).to receive(:find_channel_id).and_return(nil)
      allow(Service::SlackConnector).to receive(:send_slack_message)

      expect(described_class.resolve!(announce_channel: 'missing-channel')).to eq({})
      expect(Service::SlackConnector).not_to have_received(:send_slack_message)
    end

    it 'notifies the actor about channels that could not be resolved, without raising' do
      allow(Service::SlackConnector).to receive(:find_channel_id).and_return(nil)
      allow(Service::SlackConnector).to receive(:send_slack_message)
      slack_user = double(slack_id: 'UACTOR')
      actor = double(id: BSON::ObjectId.new, slack_user: slack_user)

      expect(described_class.resolve!({ announce_channel: 'missing-channel' }, actor)).to eq({})
      expect(Service::SlackConnector).to have_received(:send_slack_message).with(
        /couldn't verify this Slack channel: #missing-channel.*change was saved/i,
        'UACTOR'
      )
    end

    it 'resolves the channels it can and skips the ones it cannot, in a single call' do
      allow(Service::SlackConnector).to receive(:find_channel_id)
        .with('#wood-shop').and_return('C12345678')
      allow(Service::SlackConnector).to receive(:find_channel_id)
        .with('#missing-channel').and_return(nil)
      allow(Service::SlackConnector).to receive(:send_slack_message)

      result = described_class.resolve!(
        users_channel: '#wood-shop',
        announce_channel: 'missing-channel'
      )

      expect(result).to eq('users_channel' => { id: 'C12345678', name: '#wood-shop' })
    end

    it 'uses an admin token to resolve a private channel invisible to the bot, and caches it' do
      admin_client = double('Slack admin client')
      private_channel = double(id: 'G12345678', name: 'officers-private')
      response = double(
        channels: [private_channel],
        response_metadata: double(next_cursor: '')
      )
      allow(Service::SlackConnector).to receive(:find_channel_id)
        .with('#officers-private').and_return(nil)
      allow(Service::SlackConnector).to receive(:admin_client)
        .with('conversations.list').and_return(admin_client)
      expect(admin_client).to receive(:conversations_list).with(
        types: 'public_channel,private_channel',
        exclude_archived: true,
        limit: 200,
        cursor: nil
      ).and_return(response)
      expect(Service::SlackChannelCache).to receive(:store)
        .with(id: 'G12345678', name: 'officers-private')

      expect(described_class.resolve!(announce_channel: '#officers-private')).to eq(
        'announce_channel' => { id: 'G12345678', name: '#officers-private' }
      )
    end

    it 'retries resolution with the admin token when bot-token resolution raises' do
      admin_client = double('Slack admin client')
      private_channel = double(id: 'G12345678', name: 'officers-private')
      response = double(channels: [private_channel], response_metadata: double(next_cursor: ''))
      allow(Service::SlackConnector).to receive(:find_channel_id)
        .and_raise(Slack::Web::Api::Errors::SlackError.new('channel_not_found'))
      allow(Service::SlackConnector).to receive(:admin_client)
        .with('conversations.list').and_return(admin_client)
      allow(admin_client).to receive(:conversations_list).and_return(response)

      expect(described_class.resolve!(announce_channel: '#officers-private')).to eq(
        'announce_channel' => { id: 'G12345678', name: '#officers-private' }
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
      allow(client).to receive(:conversations_info)
        .and_return(double(channel: double(is_member: false)))
      allow(client).to receive(:auth_test).and_return(double(user_id: 'UBOT'))
      allow(Service::SlackConnector).to receive(:admin_client).and_return(nil)
      allow(Service::SlackConnector).to receive(:send_slack_message)
    end

    it 'first attempts to join the channel as the bot' do
      expect(client).to receive(:conversations_info).with(channel: 'C12345678')
      expect(client).to receive(:conversations_join).with(channel: 'C12345678')

      expect { described_class.invite_bot_or_notify(channels, actor) }.not_to raise_error
      expect(Service::SlackConnector).not_to have_received(:send_slack_message)
    end

    it 'does not join a channel when the bot is already a member' do
      allow(client).to receive(:conversations_info)
        .and_return(double(channel: double(is_member: true)))

      expect(client).not_to receive(:conversations_join)
      expect { described_class.invite_bot_or_notify(channels, actor) }.not_to raise_error
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
