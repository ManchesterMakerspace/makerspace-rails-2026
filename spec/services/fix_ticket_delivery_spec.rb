require 'rails_helper'
RSpec.describe FixTicketDelivery do
  let(:client) { double('Slack client') }
  let(:reporter) { build(:member, :current) }
  let(:ticket) { FixTicket.create!(reporter_id: reporter.id, title: 'Drill', description: 'Stopped', category: 'broken', submission_key: SecureRandom.uuid) }
  let(:event) { FixTicketEvent.create!(ticket_id: ticket.id, actor_id: reporter.id, kind: 'note', note: 'Switch <@USER> failed', revision: 1) }
  before do
    allow(Service::SlackConnector).to receive(:client).and_return(client)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('SLACK_TICKETS_CHANNEL').and_return('C1234567890')
    allow(ENV).to receive(:[]).with('SLACK_ENV').and_return('production')
    allow(ENV).to receive(:[]).with('SLACK_TEAM_ID').and_return('T_TEST')
    allow(ShortUrl).to receive(:base_url).and_return('https://portal.example.com')
  end
  it 'creates a root then posts a full escaped note with its thread_ts' do
    expect(client).to receive(:chat_postMessage).with(hash_including(channel: 'C1234567890', thread_ts: nil)).ordered.and_return({ 'ts' => '100.001', 'channel' => 'C1234567890' })
    expect(client).to receive(:chat_postMessage).with(hash_including(thread_ts: '100.001', text: include('Switch &lt;@USER&gt; failed'), reply_broadcast: false)).ordered.and_return({ 'ts' => '100.002', 'channel' => 'C1234567890' })
    described_class.call(ticket, event)
    expect(ticket.reload.slack_ticket_ts).to eq('100.001')
    expect(event.reload.completed_at).to be_present
  end
  it 'replaces a deleted root and broadcasts a new bounty in its thread' do
    ticket.set(slack_ticket_ts: '90.001', slack_ticket_channel_id: 'C1234567890', slack_ticket_team_id: 'T_TEST', bounty_id: BSON::ObjectId.new)
    event.set(kind: 'bounty', note: nil)
    allow(ShortUrl).to receive(:allocate).and_return(short_url: 'https://portal.example.com/L23456789AB')
    expect(client).to receive(:chat_getPermalink).and_raise(Slack::Web::Api::Errors::SlackError.new('message_not_found'))
    expect(client).to receive(:chat_postMessage).with(hash_including(thread_ts: nil)).ordered.and_return({ 'ts' => '101.001', 'channel' => 'C1234567890' })
    expect(client).to receive(:chat_postMessage).with(hash_including(thread_ts: '101.001', reply_broadcast: true)).ordered.and_return({ 'ts' => '101.002', 'channel' => 'C1234567890' })
    described_class.call(ticket, event)
    expect(ticket.reload.slack_ticket_ts).to eq('101.001')
  end
  it 'does not recreate roots on access failures' do
    ticket.set(slack_ticket_ts: '90.001', slack_ticket_channel_id: 'C1234567890', slack_ticket_team_id: 'T_TEST')
    allow(client).to receive(:chat_getPermalink).and_raise(Slack::Web::Api::Errors::SlackError.new('access_denied'))
    expect(client).not_to receive(:chat_postMessage)
    expect { described_class.call(ticket, event) }.to raise_error(Slack::Web::Api::Errors::SlackError)
    expect(ticket.reload.slack_ticket_ts).to eq('90.001')
  end
  it 'reconciles an uncertain send before retrying it' do
    allow(client).to receive(:chat_postMessage).and_raise(Timeout::Error)
    expect { described_class.call(ticket, event) }.to raise_error(Timeout::Error)
    key = event.reload.delivery_attempts.keys.first
    digest = Digest::SHA256.hexdigest("#{event.id}/#{key}")
    uuid = [digest[0,8], digest[8,4], digest[12,4], digest[16,4], digest[20,12]].join('-')
    allow(client).to receive(:conversations_history).and_return({ 'messages' => [{ 'ts' => '100.001', 'client_msg_id' => uuid }] })
    expect(client).to receive(:chat_postMessage).with(hash_including(thread_ts: '100.001')).and_return({ 'ts' => '100.002', 'channel' => 'C1234567890' })
    described_class.call(ticket, event)
    expect(event.reload.completed_at).to be_present
  end
  it 'does not backfill central publication for events created while disabled' do
    event.set(central_enabled: false)
    expect(client).not_to receive(:chat_postMessage)
    described_class.call(ticket, event)
  end

end
