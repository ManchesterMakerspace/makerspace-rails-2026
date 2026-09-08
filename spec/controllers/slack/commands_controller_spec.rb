require 'rails_helper'

RSpec.describe Slack::CommandsController, type: :controller do
  let(:secret) { 'test-signing-secret' }

  def sign_request!(body_params)
    body = body_params.to_query
    timestamp = Time.now.to_i.to_s
    signature = "v0=#{OpenSSL::HMAC.hexdigest('SHA256', secret, "v0:#{timestamp}:#{body}")}"
    request.headers['X-Slack-Request-Timestamp'] = timestamp
    request.headers['X-Slack-Signature'] = signature
  end

  describe "#verify_slack_signature" do
    context "when SLACK_SIGNING_SECRET is configured" do
      before do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with('SLACK_SIGNING_SECRET').and_return(secret)
      end

      it "accepts a correctly signed request" do
        sign_request!({ text: 'foo' })
        expect(SlackVolunteerJob).to receive(:perform_later)

        post :volunteer, params: { text: 'foo' }

        expect(response).to have_http_status(200)
      end

      it "rejects a request with an invalid signature" do
        request.headers['X-Slack-Request-Timestamp'] = Time.now.to_i.to_s
        request.headers['X-Slack-Signature'] = 'v0=bogus'
        expect(SlackVolunteerJob).not_to receive(:perform_later)

        post :volunteer, params: { text: 'foo' }

        expect(response).to have_http_status(403)
      end

      it "rejects a stale request" do
        timestamp = (Time.now - 10.minutes).to_i.to_s
        request.headers['X-Slack-Request-Timestamp'] = timestamp
        request.headers['X-Slack-Signature'] = 'v0=irrelevant-staleness-checked-first'
        expect(SlackVolunteerJob).not_to receive(:perform_later)

        post :volunteer, params: { text: 'foo' }

        expect(response).to have_http_status(403)
      end
    end

    context "when SLACK_SIGNING_SECRET is not configured" do
      before do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with('SLACK_SIGNING_SECRET').and_return(nil)
      end

      it "allows the request through in development" do
        allow(Rails.env).to receive(:development?).and_return(true)
        expect(SlackVolunteerJob).to receive(:perform_later)

        post :volunteer, params: { text: 'foo' }

        expect(response).to have_http_status(200)
      end

      it "rejects the request outside development" do
        allow(Rails.env).to receive(:development?).and_return(false)
        expect(SlackVolunteerJob).not_to receive(:perform_later)

        post :volunteer, params: { text: 'foo' }

        expect(response).to have_http_status(403)
      end
    end
  end

  describe "#checkout" do
    before do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('SLACK_SIGNING_SECRET').and_return(secret)
    end

    it "routes '/checkout request' (no tool) to SlackCheckoutRequestJob with no tool_name" do
      sign_request!({ text: 'request' })
      expect(SlackCheckoutRequestJob).to receive(:perform_later).with(hash_including('tool_name' => nil))

      post :checkout, params: { text: 'request' }

      expect(response).to have_http_status(200)
    end

    it "routes '/checkout request <tool>' to SlackCheckoutRequestJob with the tool name" do
      sign_request!({ text: 'request Bandsaw' })
      expect(SlackCheckoutRequestJob).to receive(:perform_later).with(hash_including('tool_name' => 'Bandsaw'))

      post :checkout, params: { text: 'request Bandsaw' }

      expect(response).to have_http_status(200)
    end

    it "still routes a plain '/checkout @member tool' to SlackCheckoutJob" do
      sign_request!({ text: '@someone Bandsaw' })
      expect(SlackCheckoutJob).to receive(:perform_later)
      expect(SlackCheckoutRequestJob).not_to receive(:perform_later)

      post :checkout, params: { text: '@someone Bandsaw' }

      expect(response).to have_http_status(200)
    end
  end
end
