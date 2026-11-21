require "rails_helper"

RSpec.describe "Slack reservation announcement buttons", type: :request do
  let(:shop) { create(:shop) }
  let(:member) { create(:member, :current) }
  let(:slack_id) { "URESERVATION" }
  let(:signing_secret) { "announcement-test-signing-secret" }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("SLACK_SIGNING_SECRET").and_return(signing_secret)
    allow(CloudflareRails::Importer).to receive(:cloudflare_ips).and_return([])
    allow(Service::SlackConnector).to receive(:open_modal)
    SlackUser.create!(member: member, slack_id: slack_id)
  end

  def click(shop_id: shop.id.to_s, user_id: slack_id, signature: nil)
    payload = { type: "block_actions", trigger_id: "TRIGGER", user: { id: user_id },
      response_url: "https://hooks.slack.com/actions/shared-announcement",
      actions: [{ action_id: "reservation_open", value: shop_id }] }
    body = URI.encode_www_form(payload: payload.to_json)
    timestamp = Time.now.to_i.to_s
    signature ||= "v0=#{OpenSSL::HMAC.hexdigest('SHA256', signing_secret, "v0:#{timestamp}:#{body}")}"
    post "/slack/interactions", params: body, headers: { "CONTENT_TYPE" => "application/x-www-form-urlencoded",
      "X-Slack-Request-Timestamp" => timestamp, "X-Slack-Signature" => signature }
  end

  it "opens the existing modal for the clicking active member without the public response URL" do
    click
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq({})
    expect(Service::SlackConnector).to have_received(:open_modal).with("TRIGGER", hash_including(callback_id: "reservation_submit")) do |_trigger, view|
      metadata = JSON.parse(view[:private_metadata])
      expect(metadata).to include("shop_id" => shop.id.to_s, "member_id" => member.id.to_s, "slack_user_id" => slack_id)
      expect(metadata).not_to have_key("response_url")
    end
  end

  it "ignores any member identity in the message and uses the clicking Slack user" do
    other_member = create(:member, :current)
    SlackUser.create!(member: other_member, slack_id: "UCLICKER")
    click(user_id: "UCLICKER")
    expect(Service::SlackConnector).to have_received(:open_modal) do |_trigger, view|
      expect(JSON.parse(view[:private_metadata])["member_id"]).to eq(other_member.id.to_s)
    end
  end

  it "rejects an unlinked user with a private alert" do
    click(user_id: "UUNLINKED")
    expect(Service::SlackConnector).to have_received(:open_modal).with("TRIGGER", hash_including(callback_id: "reservation_open_alert")) do |_trigger, view|
      expect(view[:blocks].first.dig(:text, :text)).to include("Link an active Member Portal account")
    end
    expect(response.parsed_body).to eq({})
  end

  %w[revoked inactive].each do |status|
    it "rejects a #{status} member despite a linked Slack account" do
      member.set(status: status)
      click
      expect(Service::SlackConnector).to have_received(:open_modal).with("TRIGGER", hash_including(callback_id: "reservation_open_alert"))
    end
  end

  it "rejects an expired member" do
    member.set(expirationTime: 1.day.ago.to_i * 1000)
    click
    expect(Service::SlackConnector).to have_received(:open_modal).with("TRIGGER", hash_including(callback_id: "reservation_open_alert"))
  end

  it "rejects a disabled shop" do
    shop.set(disabled: true)
    click
    expect(Service::SlackConnector).to have_received(:open_modal).with("TRIGGER", hash_including(callback_id: "reservation_open_alert"))
  end

  it "rejects an out-of-service shop through the shared modal policy" do
    shop.set(out_of_service: true)
    click
    expect(Service::SlackConnector).to have_received(:open_modal).with("TRIGGER", hash_including(callback_id: "reservation_open_alert")) do |_trigger, view|
      expect(view[:blocks].first.dig(:text, :text)).to eq("This shop is out of service")
    end
  end

  it "checks resource eligibility instead of granting access through the button" do
    shop.set(reservable: false)
    create(:tool, shop: shop, open: false)
    click
    expect(Service::SlackConnector).to have_received(:open_modal).with("TRIGGER", hash_including(callback_id: "reservation_open_alert")) do |_trigger, view|
      expect(view[:blocks].first.dig(:text, :text)).to include("no reservable resources")
    end
  end

  it "rejects stale or invalid shop IDs privately" do
    click(shop_id: "not-an-id")
    expect(Service::SlackConnector).to have_received(:open_modal).with("TRIGGER", hash_including(callback_id: "reservation_open_alert"))
  end

  it "preserves Slack signature verification for message actions" do
    click(signature: "v0=invalid")
    expect(response).to have_http_status(:forbidden)
    expect(Service::SlackConnector).not_to have_received(:open_modal)
  end
end
