require "rails_helper"

RSpec.describe "Slack interactions", type: :request do
  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("SLACK_SIGNING_SECRET").and_return(nil)
  end

  it "rejects unsigned requests when the signing secret is absent" do
    post "/slack/interactions", params: { payload: "{}" }

    expect(response).to have_http_status(:forbidden)
    expect(JSON.parse(response.body)).to include(
      "error" => "Slack signing secret is not configured"
    )
  end

  it "allows the missing-secret bypass in development" do
    allow(Rails.env).to receive(:development?).and_return(true)

    post "/slack/interactions", params: { payload: "{}" }

    expect(response).to have_http_status(:ok)
  end

  context "with a checkout request submission" do
    let(:shop) { create(:shop) }
    let(:tool) { create(:tool, shop: shop, open: false) }
    let(:member) { create(:member, :current) }

    before do
      allow(Rails.env).to receive(:development?).and_return(true)
      SlackUser.create!(member: member, slack_id: "USUBMITTER")
      allow(Service::SlackConnector).to receive(:send_slack_message)
    end

    def submit(tool_id: tool.id.to_s, shop_id: shop.id.to_s, user_id: "USUBMITTER", note: nil)
      payload = {
        type: "view_submission", user: { id: user_id },
        view: {
          callback_id: "checkout_request_submit",
          private_metadata: { shop_id: shop_id }.to_json,
          state: { values: {
            tool: { tool: { selected_option: { value: tool_id } } },
            note: { note: { value: note } }
          } }
        }
      }
      post "/slack/interactions", params: { payload: payload.to_json }
    end

    it "creates and announces a request with its note, then confirms receipt" do
      allow_any_instance_of(ToolCheckoutRequest).to receive(:announce_request)
      submit(note: "Please show me the blade guard")

      expect(response.parsed_body).to eq("response_action" => "clear")
      expect(ToolCheckoutRequest.last).to have_attributes(member_id: member.id, tool_id: tool.id, note: "Please show me the blade guard")
      expect(Service::SlackConnector).to have_received(:send_slack_message).with(include("unpaid volunteers"), "USUBMITTER")
    end

    it "uses the submitting Slack identity instead of trusting metadata" do
      attacker = create(:member, :current)
      SlackUser.create!(member: attacker, slack_id: "UATTACKER")
      submit(user_id: "UATTACKER")

      expect(ToolCheckoutRequest.last.member_id).to eq(attacker.id)
    end

    it "rejects a tool tampered to belong to another shop" do
      other_tool = create(:tool, open: false)
      submit(tool_id: other_tool.id.to_s)

      expect(response.parsed_body).to include("response_action" => "errors")
      expect(ToolCheckoutRequest.count).to eq(0)
    end

    it "returns a field error for duplicate submissions" do
      ToolCheckoutRequest.create!(member: member, tool: tool)
      submit

      expect(response.parsed_body.dig("errors", "tool")).to include("already have an open request")
    end

    it "returns the model's note validation as a Block Kit field error" do
      submit(note: "x" * 129)

      expect(response.parsed_body.dig("errors", "note")).to include("too long")
      expect(ToolCheckoutRequest.count).to eq(0)
    end
  end
end
