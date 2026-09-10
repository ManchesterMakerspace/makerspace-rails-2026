require "rails_helper"

RSpec.describe Service::ToolCheckoutSlackCanvas do
  let(:shop) { create(:shop, name: "Wood Shop", slack_channel: "woodshop") }

  before do
    allow(REDIS).to receive(:set).and_return(true)
    allow(REDIS).to receive(:eval).and_return(1)
    allow(Service::SlackChannelCache).to receive(:lookup)
      .with("#woodshop").and_return({ id: "C123ABC456" })
    allow(Service::SlackConnector).to receive(:find_channel_id)
    allow(Service::SlackConnector).to receive(:create_canvas)
      .and_return("FCHECKOUTS")
    allow(Service::SlackConnector).to receive(:set_canvas_user_access)
    allow(Service::SlackConnector).to receive(:set_canvas_channel_access)
    allow(Service::SlackConnector).to receive(:replace_canvas)
  end

  it "creates, caches, shares, and populates a read-only shop checkout canvas" do
    admin = create(:member, :admin)
    rm = create(
      :member,
      :resource_manager,
      firstname: "Zoe",
      lastname: "Anderson",
      resource_manager_shop_ids: [shop.id.to_s]
    )
    member = create(:member, :current, firstname: "Amy", lastname: "Zimmer")
    expired = create(:member, :expired)
    SlackUser.create!(member: rm, slack_id: "URM123456")
    SlackUser.create!(member: admin, slack_id: "UADMIN123")
    prerequisite = create(:tool, shop: shop, name: "Orientation")
    tool = create(
      :tool,
      shop: shop,
      name: "Table Saw",
      description: "Cuts lumber",
      wiki_url: "https://example.test/table-saw",
      prerequisite_ids: [prerequisite.id.to_s]
    )
    hidden = create(:tool, shop: shop, name: "Hidden Tool", disabled: true)
    ToolCheckout.create!(member: rm, tool: tool, approved_by: admin)
    ToolCheckout.create!(member: member, tool: tool, approved_by: admin)
    ToolCheckout.create!(member: expired, tool: tool, approved_by: admin)
    ToolCheckout.create!(member: member, tool: hidden, approved_by: admin)

    described_class.sync!(shop)

    expect(shop.reload.checkout_canvas_id).to eq("FCHECKOUTS")
    expect(Service::SlackConnector).to have_received(:create_canvas)
      .with("Wood Shop Checkouts", channel_id: "C123ABC456")
    expect(Service::SlackConnector).to have_received(:set_canvas_channel_access)
      .with("FCHECKOUTS", "C123ABC456")
    expect(Service::SlackConnector).to have_received(:replace_canvas) do |_id, markdown|
      expect(markdown).to include("# Wood Shop Checkouts")
      expect(markdown).to include("Current tool checkouts in ![](#C123ABC456)")
      expect(markdown).to include("- [Table Saw](#table-saw)")
      expect(markdown).to include("### Table Saw", "Cuts lumber ([Table Saw Wiki](https://example.test/table-saw))")
      expect(markdown).to include("Pre-requisites: Orientation")
      expect(markdown).to include(":ballot_box_with_check: ![](@URM123456)")
      expect(markdown).to include(":white_check_mark: Amy Zimmer")
      expect(markdown).not_to include("Hidden Tool", expired.fullname)
      expect(markdown.index("Zoe Anderson")).to be_nil
      expect(markdown).to match(/_Last updated .+\._/)
    end
  end

  it "does not create an unshared canvas when the channel cannot be resolved" do
    allow(Service::SlackChannelCache).to receive(:lookup).and_return(nil)
    allow(Service::SlackConnector).to receive(:find_channel_id).and_return(nil)

    described_class.sync!(shop)

    expect(Service::SlackConnector).not_to have_received(:create_canvas)
  end

  it "resolves private channels through Slack when they are absent from the public cache" do
    allow(Service::SlackChannelCache).to receive(:lookup).and_return(nil)
    expect(Service::SlackConnector).to receive(:find_channel_id)
      .with("#woodshop").and_return("GPRIVATE01")

    described_class.sync!(shop)

    expect(Service::SlackConnector).to have_received(:create_canvas)
      .with("Wood Shop Checkouts", channel_id: "GPRIVATE01")
  end
end
