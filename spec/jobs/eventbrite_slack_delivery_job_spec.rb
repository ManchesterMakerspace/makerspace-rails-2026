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

  it 'keeps a concurrent ticket update queued until the new counts are sent' do
    delivery.set(ts: '123.456', channel: 'CTEST')
    event.set(tickets_sold: 1, tickets_remaining: 9)
    allow(slack).to receive(:chat_update) do
      event.set(tickets_sold: 2, tickets_remaining: 8)
      EventbriteSlackDelivery.find(delivery.id).inc(revision: 1)
      { 'ok' => true }
    end
    described_class.perform_now(delivery.id.to_s)
    expect(delivery.reload.due_at).to be_present
    expect(delivery.delivered_revision).to be < delivery.revision
    allow(slack).to receive(:chat_update).and_return({ 'ok' => true })
    described_class.perform_now(delivery.id.to_s)
    expect(delivery.reload.due_at).to be_nil
    expect(slack).to have_received(:chat_update).with(hash_including(text: include('2 sold · 8 remaining')))
  end

  it 'retries the SDK rate-limit exception without marking the post ambiguous' do
    response = Faraday::Response.new(status: 429, response_headers: { 'retry-after' => '90' }, body: { 'ok' => false, 'error' => 'ratelimited' })
    error = Slack::Web::Api::Errors::TooManyRequestsError.new(response)
    allow(slack).to receive(:chat_postMessage).and_raise(error)
    described_class.perform_now(delivery.id.to_s)
    expect(delivery.reload.failed_at).to be_nil
    expect(delivery.sending_at).to be_nil
    expect(delivery.attempts).to eq(0)
    expect(delivery.due_at).to be_within(3.seconds).of(90.seconds.from_now)
    expect(delivery.last_error).to include('TooManyRequestsError', 'Retry after 90')
    travel 91.seconds do
      allow(slack).to receive(:chat_postMessage).and_return({ 'channel' => 'CTEST', 'ts' => '123.456' })
      described_class.perform_now(delivery.id.to_s)
    end
    expect(delivery.reload.ts).to eq('123.456')
    expect(delivery.last_error).to be_nil
  end

  it 'records actionable, filtered Slack diagnostics for a definite rejection' do
    response = Faraday::Response.new(status: 200, body: {
      'ok' => false, 'error' => 'invalid_blocks_format', 'token' => 'secret-value',
      'response_metadata' => { 'messages' => ['Invalid blocks at /blocks/1; received xoxb-secret-value'] }
    })
    allow(slack).to receive(:chat_postMessage).and_raise(Slack::Web::Api::Errors::SlackError.new('invalid_blocks_format', response))
    described_class.perform_now(delivery.id.to_s)
    expect(delivery.reload.failed_at).to be_present
    expect(delivery.sending_at).to be_nil
    expect(delivery.last_error).to include('invalid_blocks_format', '/blocks/1')
    expect(delivery.last_error).not_to include('secret-value', 'AMBIGUOUS_SEND')
  end

  it 'preserves ambiguity and the cause after a timeout while posting' do
    allow(slack).to receive(:chat_postMessage).and_raise(Faraday::TimeoutError.new('execution expired for xoxb-sensitive-token'))
    described_class.perform_now(delivery.id.to_s)
    expect(delivery.reload.failed_at).to be_present
    expect(delivery.sending_at).to be_present
    expect(delivery.last_error).to include('AMBIGUOUS_SEND', 'Faraday::TimeoutError', 'execution expired')
    expect(delivery.last_error).not_to include('xoxb-sensitive-token')
    described_class.perform_now(delivery.id.to_s)
    expect(slack).to have_received(:chat_postMessage).once
  end
end
