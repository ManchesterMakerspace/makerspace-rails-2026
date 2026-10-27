require 'rails_helper'

RSpec.describe Service::SlackMessageLog do
  let(:client) { instance_double(Slack::Web::Client) }

  around do |example|
    described_class.enabled = true
    example.run
  ensure
    described_class.enabled = false
  end

  # The connector skips Slack entirely in the test environment. Switch that off,
  # and swap in the fake Slack client, only after test records exist, so
  # creating a member does not run the Slack invite flow against the fake.
  def live!
    allow(Rails.env).to receive(:test?).and_return(false)
    allow(Service::SlackConnector).to receive(:client).and_return(client)
  end

  def entries = AuditLog.where(log_type: 'slack').order_by(created_at: :asc).to_a

  describe 'SlackConnector.send_slack_message' do
    it 'records a channel post with its text, channel, receipt and the sending code' do
      live!
      allow(client).to receive(:chat_postMessage).and_return({ 'ok' => true, 'channel' => 'C123', 'ts' => '111.222' })

      Service::SlackConnector.send_slack_message('Bandsaw is out of service', 'shop-woodworking')

      expect(entries.size).to eq(1)
      entry = entries.first
      expect(entry.event_type).to eq('slack_message_sent')
      expect(entry.category).to eq('slack')
      expect(entry.resource_type).to eq('SlackChannel')
      expect(entry.resource_id).to eq('shop-woodworking')
      expect(entry.slack_channel).to eq('shop-woodworking')
      expect(entry.slack_message).to eq('Bandsaw is out of service')
      expect(entry.slack_posted).to be(true)
      expect(entry.subject_id).to be_nil
      expect(entry.after_snapshot).to include('ts' => '111.222', 'delivered_channel' => 'C123')
      expect(entry.after_snapshot['source']).to include('slack_message_log_spec')
    end

    it 'names the member as subject when the message is a DM to their Slack ID' do
      member = create(:member)
      SlackUser.create!(member: member, slack_id: 'U0DMTEST1')
      live!
      allow(client).to receive(:chat_postMessage).and_return({ 'ok' => true, 'channel' => 'D1', 'ts' => '1.1' })

      Service::SlackConnector.send_slack_message('Your checkout was approved', 'U0DMTEST1')

      expect(entries.first.subject_id).to eq(member.id)
      expect(entries.first.subject_name).to eq(member.fullname)
    end

    it 'records a failed post and still raises the error' do
      live!
      error = Slack::Web::Api::Errors::SlackError.new('channel_not_found')
      allow(client).to receive(:chat_postMessage).and_raise(error)

      expect { Service::SlackConnector.send_slack_message('hello', 'missing-channel') }
        .to raise_error(Slack::Web::Api::Errors::SlackError)

      expect(entries.size).to eq(1)
      expect(entries.first.event_type).to eq('slack_message_failed')
      expect(entries.first.slack_posted).to be(false)
      expect(entries.first.after_snapshot['error']).to include('channel_not_found')
    end

    it 'stores the visible text of Block Kit messages' do
      live!
      blocks = [{ 'type' => 'section', 'text' => { 'type' => 'mrkdwn', 'text' => '*Request* for Lathe' } },
                { 'type' => 'context', 'elements' => [{ 'type' => 'mrkdwn', 'text' => 'Requested today' }] }]
      allow(client).to receive(:chat_postMessage).and_return({ 'ok' => true, 'ts' => '2.2' })

      Service::SlackConnector.send_slack_message(blocks, 'shop-metal')

      expect(entries.first.slack_message).to eq("*Request* for Lathe\nRequested today")
    end

    it 'does not record sends made inside without_logging, and records again afterwards' do
      live!
      allow(client).to receive(:chat_postMessage).and_return({ 'ok' => true, 'ts' => '3.3' })

      described_class.without_logging { Service::SlackConnector.send_slack_message('already audited', 'logs') }
      expect(entries).to be_empty

      Service::SlackConnector.send_slack_message('normal', 'logs')
      expect(entries.map(&:slack_message)).to eq(['normal'])
    end

    it 'never blocks or breaks the message when the audit write fails' do
      live!
      allow(client).to receive(:chat_postMessage).and_return({ 'ok' => true, 'ts' => '4.4' })
      allow(AuditLog).to receive(:create!).and_raise(Mongo::Error::OperationFailure, 'write failed')

      response = Service::SlackConnector.send_slack_message('still delivered', 'shop-paint')

      expect(response['ts']).to eq('4.4')
    end

    it 'uses the source it is given (the queued-message path passes the queuing code)' do
      live!
      allow(client).to receive(:chat_postMessage).and_return({ 'ok' => true, 'ts' => '5.5' })

      Service::SlackConnector.send_slack_messages(['one', 'two'], 'members-relations', source: 'Admin::RentalsController#create')

      expect(entries.first.after_snapshot['source']).to eq('Admin::RentalsController#create')
    end
  end

  describe 'AuditLogger posts' do
    it 'are not recorded twice: the audit entry itself already records the post' do
      member = create(:member)
      live!
      allow(client).to receive(:chat_postMessage).and_return({ 'ok' => true, 'ts' => '6.6' })

      Service::AuditLogger.log(log_type: 'member', event_type: 'member_updated', resource_type: 'Member',
                               resource_id: member.id, subject: member, slack_channel: 'logs')

      expect(AuditLog.where(log_type: 'slack').count).to eq(0)
      expect(AuditLog.where(event_type: 'member_updated').first.slack_posted).to be(true)
    end
  end

  describe 'when disabled (the default in the test environment)' do
    it 'records nothing' do
      live!
      described_class.enabled = false
      allow(client).to receive(:chat_postMessage).and_return({ 'ok' => true, 'ts' => '7.7' })

      Service::SlackConnector.send_slack_message('quiet', 'shop-paint')

      expect(entries).to be_empty
    end
  end

  describe '.text_of' do
    it 'shortens very long messages' do
      live!
      text = described_class.text_of('x' * 5000)
      expect(text.length).to eq(Service::SlackMessageLog::MAX_TEXT + 1)
      expect(text).to end_with('…')
    end
  end
end
