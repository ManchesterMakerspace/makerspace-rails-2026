require 'rails_helper'

RSpec.describe EventbriteSlackDeliveryJob do
  let(:event) { EventbriteEvent.create!(organization_id: 'org', eventbrite_id: 'one', name: 'Test event', status: 'live', listed: true, starts_at: 2.hours.from_now) }
  let(:slack) { double('Slack') }
  let(:delivery) { EventbriteIntegration::Announcements.new.request(event, 'publication', ['one']) }
  before do
    allow(EventbriteIntegration::Configuration).to receive(:validate!)
    allow(EventbriteIntegration::Configuration).to receive(:organization_allowed?).and_return(true)
    allow(Service::SlackConnector).to receive(:client).and_return(slack)
    allow(Service::SlackConnector).to receive(:resolved_channel_id).and_return('CTEST')
  end

  it 'saves and mirrors a receipt, then edits that channel after configuration changes' do
    allow(slack).to receive(:chat_postMessage).and_return({ 'channel' => 'CTEST', 'ts' => '123.456' })
    allow(slack).to receive(:chat_update).and_return({ 'ok' => true })
    described_class.perform_now(delivery.id.to_s)
    expect(event.reload.slack_receipts.fetch(delivery.id.to_s)['ts']).to eq('123.456')
    delivery.reload.inc(revision: 1)
    delivery.set(due_at: Time.current)
    SystemConfig.set('slack_channel_upcoming_events', 'elsewhere')
    described_class.perform_now(delivery.id.to_s)
    expect(slack).to have_received(:chat_postMessage).once
    expect(slack).to have_received(:chat_update).with(hash_including(channel: 'CTEST', ts: '123.456', blocks: anything))
  end

  it 'does not repost an ambiguous send after an interrupted worker' do
    delivery.set(sending_at: Time.current)
    expect(slack).not_to receive(:chat_postMessage)
    described_class.perform_now(delivery.id.to_s)
    expect(delivery.reload.failed_at).to be_present
  end

  it 'expires unposted past reminders' do
    delivery.update!(kind: 'reminder', day: '2000-01-01')
    expect(slack).not_to receive(:chat_postMessage)
    described_class.perform_now(delivery.id.to_s)
    expect(delivery.reload.expired).to be(true)
  end

  it 'repairs receipt mirroring without repeating a successful send' do
    delivery.set(ts: '123.456', channel: 'CTEST', delivered_revision: delivery.revision)
    expect(slack).not_to receive(:chat_postMessage)
    expect(slack).not_to receive(:chat_update)
    described_class.perform_now(delivery.id.to_s)
    expect(event.reload.slack_receipts.fetch(delivery.id.to_s)['channel']).to eq('CTEST')
    expect(delivery.reload.due_at).to be_nil
  end
end
