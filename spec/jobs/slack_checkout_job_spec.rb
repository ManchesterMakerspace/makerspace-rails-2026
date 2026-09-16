require "rails_helper"

RSpec.describe SlackCheckoutJob do
  let(:shop) { create(:shop, slack_channel: "C12345678") }
  let(:tool) { create(:tool, shop: shop, name: "Bandsaw") }
  let(:approver) { create(:member, :current, :admin) }
  let(:member) { create(:member, :current) }

  before do
    SlackUser.create!(member: approver, slack_id: "UAPPROVER")
    allow(REDIS).to receive(:set).and_return(true)
    allow(REDIS).to receive(:del)
    allow_any_instance_of(ToolCheckout).to receive(:send_checkout_slack_notification)
    allow_any_instance_of(ToolCheckout).to receive(:announce_checkout_success)

    http = instance_double(Net::HTTP)
    allow(Net::HTTP).to receive(:new).and_return(http)
    allow(http).to receive(:use_ssl=)
    allow(http).to receive(:request)
  end

  it "resolves the shop from channel_id when channel_name is human-readable" do
    expect {
      described_class.perform_now(
        "response_url" => "https://example.test/response",
        "user_id" => "UAPPROVER",
        "channel_name" => "woodshop",
        "channel_id" => "C12345678",
        "text" => "#{member.email} #{tool.name}"
      )
    }.to change {
      ToolCheckout.where(member_id: member.id, tool_id: tool.id, revoked_at: nil).count
    }.by(1)
  end
end
