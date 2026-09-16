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

    it "opens an eligible-tool modal for '/checkout request' with no tool name" do
      shop = create(:shop, slack_channel: "woodshop")
      member = create(:member, :current)
      create(:tool, shop: shop)
      SlackUser.create!(member: member, slack_id: "U123", slack_email: member.email)
      sign_request!({ text: 'request', channel_name: "woodshop", user_id: "U123", trigger_id: "trigger" })
      expect(Service::SlackConnector).to receive(:open_modal).with("trigger", hash_including(callback_id: "checkout_request_submit"))

      post :checkout, params: { text: 'request', channel_name: "woodshop", user_id: "U123", trigger_id: "trigger" }

      expect(response).to have_http_status(200)
    end

    it "routes '/checkout request <tool>' to SlackCheckoutRequestJob with the tool name" do
      shop = create(:shop, slack_channel: "woodshop")
      member = create(:member, :current)
      SlackUser.create!(member: member, slack_id: "U123")
      request_params = { text: 'request Bandsaw', channel_name: "woodshop", user_id: "U123" }
      sign_request!(request_params)
      expect(SlackCheckoutRequestJob).to receive(:perform_later).with(hash_including('tool_name' => 'Bandsaw'))

      post :checkout, params: request_params

      expect(response).to have_http_status(200)
    end

    it "lists all open requests when '/checkout request' is used outside a shop channel" do
      member = create(:member, :current)
      tool = create(:tool, name: "Bandsaw")
      ToolCheckoutRequest.create!(member: member, tool: tool, status: "open")
      SlackUser.create!(member: member, slack_id: "U123", slack_email: member.email)
      request_params = { text: "request", channel_name: "general", user_id: "U123" }
      sign_request!(request_params)

      post :checkout, params: request_params

      expect(response.parsed_body.fetch("text")).to include("Bandsaw", tool.shop.name, "open checkout requests")
    end

    it "suggests volunteering as an approver when the requester has an active checkout in the shop" do
      shop = create(:shop, slack_channel: "woodshop")
      member = create(:member, :current)
      create(:tool_checkout, member: member, tool: create(:tool, shop: shop))
      create(:tool, shop: shop)
      SlackUser.create!(member: member, slack_id: "U123", slack_email: member.email)
      request_params = { text: "request", channel_name: "woodshop", user_id: "U123", trigger_id: "trigger" }
      sign_request!(request_params)
      allow(Service::SlackConnector).to receive(:open_modal)

      post :checkout, params: request_params

      expect(response.parsed_body.fetch("text")).to include("Volunteering as a checkout approver")
    end

    it "routes '/checkout active' to SlackCheckoutActiveJob" do
      sign_request!({ text: "active" })
      expect(SlackCheckoutActiveJob).to receive(:perform_later).with(hash_including("text" => "active"))

      post :checkout, params: { text: "active" }
      expect(response).to have_http_status(200)
    end

    it "lists the active command in bare checkout help" do
      sign_request!({ text: "" })
      post :checkout, params: { text: "" }
      expect(response.parsed_body.fetch("text")).to include("/checkout active [all]")
    end

    it "still routes a plain '/checkout @member tool' to SlackCheckoutJob" do
      create(:shop, slack_channel: "woodshop")
      member = create(:member, :current)
      SlackUser.create!(member: member, slack_id: "U123")
      request_params = { text: '@someone Bandsaw', channel_name: "woodshop", user_id: "U123" }
      sign_request!(request_params)
      expect(SlackCheckoutJob).to receive(:perform_later)
      expect(SlackCheckoutRequestJob).not_to receive(:perform_later)

      post :checkout, params: request_params

      expect(response).to have_http_status(200)
    end


    it "synchronizes an unknown Slack identity before opening a request modal" do
      shop = create(:shop, slack_channel: "woodshop")
      create(:tool, shop: shop)
      member = create(:member, :current)
      request_params = { text: "request", channel_name: "woodshop", user_id: "UNEW", trigger_id: "trigger" }
      sign_request!(request_params)
      expect(Service::SlackUserSync).to receive(:sync_single).with("UNEW") do
        SlackUser.create!(member: member, slack_id: "UNEW")
        member
      end
      allow(Service::SlackConnector).to receive(:open_modal)

      post :checkout, params: request_params
      expect(response).to have_http_status(200)
    end
  end
end
