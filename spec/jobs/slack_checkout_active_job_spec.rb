require "rails_helper"

RSpec.describe SlackCheckoutActiveJob do
  let(:member) { create(:member, :current) }
  let!(:slack_user) { SlackUser.create!(member: member, slack_id: "U123", slack_email: member.email) }
  let(:posted_bodies) { [] }

  before do
    http = instance_double(Net::HTTP)
    allow(Net::HTTP).to receive(:new).and_return(http)
    allow(http).to receive(:use_ssl=)
    allow(http).to receive(:request) { |request| posted_bodies << JSON.parse(request.body) }
  end

  def perform(text: "active", channel: "woodshop")
    described_class.perform_now(
      "response_url" => "https://example.test/response",
      "user_id" => slack_user.slack_id,
      "channel_name" => channel,
      "text" => text
    )
  end

  it "lists the current shop's active checkouts alphabetically with status and approver status" do
    shop = create(:shop, slack_channel: "woodshop")
    zulu = create(:tool, shop: shop, name: "Zulu", disabled: true)
    alpha = create(:tool, shop: shop, name: "Alpha")
    create(:tool_checkout, member: member, tool: zulu)
    create(:tool_checkout, member: member, tool: alpha)
    CheckoutApprover.create!(member: member, tool_ids: [alpha.id.to_s])

    perform

    text = posted_bodies.last.fetch("text")
    expect(text.index("Alpha")).to be < text.index("Zulu")
    expect(text).to include("Enabled", "Disabled", "Approver", "Yes", "No")
  end

  it "treats a shop resource manager as an approver" do
    shop = create(:shop, slack_channel: "woodshop")
    member.update!(role: "resource_manager", resource_manager_shop_ids: [shop.id.to_s])
    create(:tool_checkout, member: member, tool: create(:tool, shop: shop, name: "Lathe"))

    perform
    expect(posted_bodies.last.fetch("text")).to match(/Lathe\s+\| Enabled\s+\| Yes/)
  end

  it "lists all checked-out shops alphabetically with names and channels for active all or an unrelated channel" do
    zulu_shop = create(:shop, name: "Zulu Shop", slack_channel: "zulu")
    alpha_shop = create(:shop, name: "Alpha Shop", slack_channel: "alpha")
    create(:tool_checkout, member: member, tool: create(:tool, shop: zulu_shop))
    create(:tool_checkout, member: member, tool: create(:tool, shop: alpha_shop))

    perform(text: "active all")
    text = posted_bodies.last.fetch("text")
    expect(text.index("Alpha Shop")).to be < text.index("Zulu Shop")
    expect(text).to include("#alpha", "#zulu")

    perform(channel: "general")
    expect(posted_bodies.last.fetch("text")).to include("Alpha Shop", "Zulu Shop")
  end
end
