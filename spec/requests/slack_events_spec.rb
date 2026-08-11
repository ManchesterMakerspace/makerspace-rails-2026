require 'rails_helper'

RSpec.describe 'Slack Events API', type: :request do
  let(:secret) { 'signing-secret' }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('SLACK_SIGNING_SECRET').and_return(secret)
    allow(REDIS).to receive(:set).and_return(true)
    allow(REDIS).to receive(:del)
    allow(Service::SlackUserEvents).to receive(:process)
  end

  def signed_headers(body, timestamp: Time.now.to_i)
    signature = OpenSSL::HMAC.hexdigest('SHA256', secret, "v0:#{timestamp}:#{body}")
    {
      'CONTENT_TYPE' => 'application/json',
      'X-Slack-Request-Timestamp' => timestamp.to_s,
      'X-Slack-Signature' => "v0=#{signature}"
    }
  end

  it 'answers Slack URL verification challenges' do
    body = { type: 'url_verification', challenge: 'challenge-token' }.to_json

    post '/slack/events', params: body, headers: signed_headers(body)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq('challenge' => 'challenge-token')
  end

  it 'processes supported member events before acknowledging them' do
    event = { type: 'team_join', user: { id: 'U123' } }
    body = { type: 'event_callback', event_id: 'Ev123', event: event }.to_json

    post '/slack/events', params: body, headers: signed_headers(body)

    expect(response).to have_http_status(:ok)
    expect(Service::SlackUserEvents).to have_received(:process)
      .with(event.deep_stringify_keys, event_id: 'Ev123')
  end

  it 'does not process a redelivered event twice' do
    event = { type: 'team_join', user: { id: 'U123' } }
    body = { type: 'event_callback', event_id: 'Ev-duplicate', event: event }.to_json
    allow(REDIS).to receive(:set).and_return(true, false)

    2.times { post '/slack/events', params: body, headers: signed_headers(body) }

    expect(Service::SlackUserEvents).to have_received(:process).once

    expect(REDIS).to have_received(:set).with(
      "slack_event/#{Digest::SHA256.hexdigest('Ev-duplicate')}",
      1,
      nx: true,
      ex: Slack::EventsController::EVENT_DEDUPLICATION_TTL
    ).twice
  end

  it 'rejects callbacks without an event ID' do
    body = { type: 'event_callback', event: { type: 'team_join', user: { id: 'U123' } } }.to_json

    post '/slack/events', params: body, headers: signed_headers(body)

    expect(response).to have_http_status(:bad_request)
    expect(Service::SlackUserEvents).not_to have_received(:process)
  end

  it 'rejects invalid signatures' do
    body = { type: 'event_callback', event: {} }.to_json

    post '/slack/events', params: body, headers: signed_headers(body).merge(
      'X-Slack-Signature' => 'v0=invalid'
    )

    expect(response).to have_http_status(:forbidden)
  end
end
