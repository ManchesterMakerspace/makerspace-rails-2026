require 'rails_helper'

RSpec.describe 'Slack channel error logging' do
  let(:connector) { Service::SlackConnector }
  let(:client) { connector.client }
  let(:stubs) { Faraday::Adapter::Test::Stubs.new }

  around do |example|
    previous = ENV.to_h.slice('SLACK_ENV', 'SLACK_BOT_TOKEN', 'SLACK_ADMIN_TOKEN')
    ENV['SLACK_ENV'] = 'production'
    ENV['SLACK_BOT_TOKEN'] = 'xoxb-test-secret'
    ENV['SLACK_ADMIN_TOKEN'] = 'xoxp-test-secret'
    example.run
  ensure
    %w[SLACK_ENV SLACK_BOT_TOKEN SLACK_ADMIN_TOKEN].each { |key| ENV[key] = previous[key] }
  end

  before do
    allow(Rails.logger).to receive(:error)
    allow(Slack::Web::Client).to receive(:new).and_wrap_original do |original, *arguments|
      sdk_client = original.call(*arguments)
      sdk_client.send(:connection).builder.adapter(:test, stubs)
      sdk_client
    end
    # The diagnostic must not call Slack to report Slack's own failure.
    expect(connector).not_to receive(:send_slack_message)
  end

  def reject_request(operation, method: :post, error: 'channel_not_found')
    requests = []
    stubs.public_send(method, "/api/#{operation}") do |env|
      requests << Faraday::Utils.parse_nested_query(env.body)
      [200, { 'Content-Type' => 'application/json' }, { ok: false, error: error, token: 'response-secret' }.to_json]
    end
    requests
  end

  [nil, 'general', '#general', 'C12345678'].each do |channel|
    it "logs the actual channel #{channel.inspect} from a provider rejection" do
      reject_request('chat.postMessage')
      expect do
        # Low-level post also covers nil; generated SDK helpers reject nil before HTTP.
        expect { client.post('chat.postMessage', channel: channel, text: 'private message') }
          .to raise_error(Slack::Web::Api::Errors::ChannelNotFound)
      end.to output(a_string_including('[SlackChannelNotFound]', '"operation":"chat.postMessage"',
        "\"channel\":#{channel.to_json}")).to_stderr
      expect(Rails.logger).to have_received(:error).with(a_string_including("\"channel\":#{channel.to_json}"))
      expect(Rails.logger).not_to have_received(:error).with(a_string_including('private message'))
      expect(Rails.logger).not_to have_received(:error).with(a_string_including('response-secret'))
      expect(Rails.logger).not_to have_received(:error).with(a_string_including('test-secret'))
    end
  end

  it 'logs a missing channel parameter as null' do
    reject_request('conversations.list', method: :get)
    expect do
      expect { client.get('conversations.list') }.to raise_error(Slack::Web::Api::Errors::ChannelNotFound)
    end.to output(a_string_including('"channel":null', '"operation":"conversations.list"')).to_stderr
  end

  it 'logs string-keyed channel parameters on direct requests' do
    reject_request('chat.delete', method: :delete)
    expect do
      expect { client.delete('chat.delete', 'channel' => 'C12345678', 'ts' => '123.456') }
        .to raise_error(Slack::Web::Api::Errors::ChannelNotFound)
    end.to output(a_string_including('"channel":"C12345678"', '"operation":"chat.delete"')).to_stderr
  end

  it 'covers generated edit endpoints and retains their error behavior' do
    reject_request('chat.update')
    expect do
      expect { client.chat_update(channel: 'C12345678', ts: '123.456', text: 'Changed') }
        .to raise_error(Slack::Web::Api::Errors::ChannelNotFound)
    end.to output(a_string_including('"channel":"C12345678"', '"operation":"chat.update"')).to_stderr
  end

  it 'covers the admin client and channel ID arrays' do
    reject_request('canvases.access.set')
    expect do
      expect { connector.admin_client('canvases.access.set').canvases_access_set(
        canvas_id: 'F123', access_level: 'read', channel_ids: ['C12345678'].to_json
      ) }.to raise_error(Slack::Web::Api::Errors::ChannelNotFound)
    end.to output(a_string_including('"channel_ids":', 'C12345678', '"operation":"canvases.access.set"')).to_stderr
  end

  it 'includes the alternate channel_id field without exposing other arguments' do
    reject_request('canvases.create')
    expect do
      expect { client.canvases_create(channel_id: 'C12345678', title: 'Private title') }
        .to raise_error(Slack::Web::Api::Errors::ChannelNotFound)
    end.to output(a_string_including('"channel_id":"C12345678"')).to_stderr
    expect(Rails.logger).not_to have_received(:error).with(a_string_including('Private title'))
  end

  it 'logs the redirected test channel on every rejected posting attempt' do
    ENV['SLACK_ENV'] = 'development'
    requests = reject_request('chat.postMessage')
    expect do
      expect { connector.post_slack_message('Private body', 'general') }
        .to raise_error(Slack::Web::Api::Errors::ChannelNotFound)
    end.to output(a_string_including('"channel":"test_channel"', '"mode":"test"')).to_stderr
    expect(requests.map { |body| body.fetch('channel') }).to eq(%w[test_channel test_channel])
    expect(Rails.logger).to have_received(:error).with(a_string_including('"channel":"test_channel"')).twice
  end

  it 'preserves the original exception even when the logger fails' do
    error = Slack::Web::Api::Errors::ChannelNotFound.new('channel_not_found for xoxb-sensitive-token')
    connection = double('connection')
    allow(client).to receive(:connection).and_return(connection)
    allow(connection).to receive(:post).and_raise(error)
    allow(Rails.logger).to receive(:error).and_raise(IOError, 'log unavailable')
    expect do
      expect { client.post('chat.postMessage', channel: 'general') }.to raise_error { |raised| expect(raised).to be(error) }
    end.to output(a_string_including('[FILTERED]')).to_stderr
  end

  it 'leaves unrelated errors and successful responses alone' do
    reject_request('chat.postMessage', error: 'not_in_channel')
    expect do
      expect { client.chat_postMessage(channel: 'general', text: 'Hello') }
        .to raise_error(Slack::Web::Api::Errors::NotInChannel)
    end.to output('').to_stderr
    stubs.post('/api/chat.postMessage') do
      [200, { 'Content-Type' => 'application/json' }, { ok: true, channel: 'C12345678', ts: '123.456' }.to_json]
    end
    expect(client.chat_postMessage(channel: 'general', text: 'Hello').ts).to eq('123.456')
    expect(Rails.logger).not_to have_received(:error)
  end
end
