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
    let!(:shop) { create(:shop, slack_channel: "woodshop") }
    let!(:tool) { create(:tool, shop: shop, open: false) }
    let!(:member) { create(:member, :current) }
    let!(:slack_user) { SlackUser.create!(member: member, slack_id: "U123") }

    before do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('SLACK_SIGNING_SECRET').and_return(secret)
    end

    it "opens the self-service modal synchronously for an ordinary member's bare command" do
      sign_request!({ text: '', user_id: "U123", channel_name: "woodshop", trigger_id: "trigger" })
      expect(Service::SlackConnector).to receive(:open_modal).with("trigger", hash_including(callback_id: "checkout_request_submit"))

      post :checkout, params: { text: '', user_id: "U123", channel_name: "woodshop", trigger_id: "trigger" }

      expect(response).to have_http_status(200)
    end

    it "opens the modal for an approver who explicitly uses '/checkout request'" do
      create(:checkout_approver, member: member, shop_ids: [shop.id])
      sign_request!({ text: 'request', user_id: "U123", channel_name: "woodshop", trigger_id: "trigger" })
      expect(Service::SlackConnector).to receive(:open_modal)

      post :checkout, params: { text: 'request', user_id: "U123", channel_name: "woodshop", trigger_id: "trigger" }

      expect(response).to have_http_status(200)
    end

    it "still routes a plain '/checkout @member tool' to SlackCheckoutJob" do
      sign_request!({ text: '@someone Bandsaw', user_id: "U123", channel_name: "woodshop" })
      expect(SlackCheckoutJob).to receive(:perform_later)
      expect(SlackCheckoutRequestJob).not_to receive(:perform_later)

      post :checkout, params: { text: '@someone Bandsaw', user_id: "U123", channel_name: "woodshop" }

      expect(response).to have_http_status(200)
    end
  end
end
