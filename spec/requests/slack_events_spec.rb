require 'rails_helper'

RSpec.describe 'Slack Events API', type: :request do
  let(:secret) { 'signing-secret' }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('SLACK_SIGNING_SECRET').and_return(secret)
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

  it 'queues supported member events' do
    event = { type: 'team_join', user: { id: 'U123' } }
    body = { type: 'event_callback', event: event }.to_json

    expect do
      post '/slack/events', params: body, headers: signed_headers(body)
    end.to have_enqueued_job(SlackUserEventJob).with(event.deep_stringify_keys)

    expect(response).to have_http_status(:ok)
  end

  it 'rejects invalid signatures' do
    body = { type: 'event_callback', event: {} }.to_json

    post '/slack/events', params: body, headers: signed_headers(body).merge(
      'X-Slack-Signature' => 'v0=invalid'
    )

    expect(response).to have_http_status(:forbidden)
  end
end
