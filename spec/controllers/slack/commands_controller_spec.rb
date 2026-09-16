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
      allow(Service::ShopSlackChannels).to receive(:associated?).and_return(true)
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

    it "synchronizes an unknown Slack identity before rejecting the command" do
      slack_user.destroy
      sign_request!({ text: '', user_id: "UNEW", channel_name: "woodshop", trigger_id: "trigger" })
      expect(Service::SlackUserSync).to receive(:sync_single).with("UNEW") do
        SlackUser.create!(member: member, slack_id: "UNEW")
        member
      end
      expect(Service::SlackConnector).to receive(:open_modal)

      post :checkout, params: { text: '', user_id: "UNEW", channel_name: "woodshop", trigger_id: "trigger" }

      expect(response).to have_http_status(200)
    end

    it "still routes a plain '/checkout @member tool' to SlackCheckoutJob" do
      sign_request!({ text: '@someone Bandsaw', user_id: "U123", channel_name: "woodshop" })
      expect(SlackCheckoutJob).to receive(:perform_later)
      expect(SlackCheckoutRequestJob).not_to receive(:perform_later)

      post :checkout, params: { text: '@someone Bandsaw', user_id: "U123", channel_name: "woodshop" }

      expect(response).to have_http_status(200)
    end

    context "outside a configured shop channel" do
      let(:wood_shop) { create(:shop, name: "Wood Shop") }
      let(:metal_shop) { create(:shop, name: "Metal Shop") }
      let(:channels) do
        [
          Service::ShopSlackChannels::Channel.new(shop: wood_shop, id: "C12345678", name: "#wood-shop"),
          Service::ShopSlackChannels::Channel.new(shop: metal_shop, id: "C23456789", name: "#metal-shop")
        ]
      end

      before do
        allow(Service::ShopSlackChannels).to receive(:associated?).and_return(false)
        allow(Service::ShopSlackChannels).to receive(:resolved).and_return(channels)
      end

      ["", "request", "request Bandsaw", "@someone Bandsaw"].each do |command_text|
        it "directs '#{command_text.presence || 'bare /checkout'}' to the public shop channels" do
          sign_request!(text: command_text, channel_name: "general")

          post :checkout, params: { text: command_text, channel_name: "general" }

          payload = response.parsed_body
          expect(payload["response_type"]).to eq("ephemeral")
          expect(payload["text"]).to include(
            "appropriate shop channel",
            "<#C12345678> — *Wood Shop*",
            "<#C23456789> — *Metal Shop*",
            "Join the appropriate channel",
            "`/checkout` there"
          )
          expect(SlackCheckoutJob).not_to have_been_enqueued
          expect(SlackCheckoutRequestJob).not_to have_been_enqueued
        end
      end

      it "uses generic instructions when no public channels can be resolved" do
        allow(Service::ShopSlackChannels).to receive(:resolved).and_return([])
        sign_request!(text: "request", channel_name: "general")

        post :checkout, params: { text: "request", channel_name: "general" }

        expect(response.parsed_body["text"]).to include(
          "appropriate shop channel",
          "join the public Slack channel",
          "run `/checkout` there"
        )
      end

      it "uses generic instructions when channel inventory is unavailable" do
        allow(Service::ShopSlackChannels).to receive(:resolved).and_raise(Redis::CannotConnectError)
        sign_request!(text: "", channel_name: "general")

        expect do
          post :checkout, params: { text: "", channel_name: "general" }
        end.not_to raise_error

        expect(response.parsed_body["text"]).to include("join the public Slack channel")
      end
    end
  end
end
