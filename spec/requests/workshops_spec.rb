require "rails_helper"

RSpec.describe "Workshops", type: :request do
  let(:member) { create(:member, :current) }
  let!(:shop) { create(:shop, name: "Wood Shop") }
  let!(:disabled_shop) { create(:shop, name: "Closed Shop", disabled: true) }
  let!(:visible_tool) { create(:tool, shop: shop, name: "Planer") }
  let!(:checked_out_hidden_tool) do
    create(:tool, shop: shop, name: "Hidden Saw", disabled: true)
  end
  let!(:other_hidden_tool) do
    create(:tool, shop: shop, name: "Hidden Lathe", disabled: true)
  end

  before do
    create(:tool_checkout, member: member, tool: checked_out_hidden_tool)
    sign_in member
  end

  it "hides disabled shops and shows hidden tools only when checked out" do
    get "/api/workshops"

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body["canAddShop"]).to be(false)
    expect(body["workshops"].map { |row| row["name"] }).to eq(["Wood Shop"])
    tool_names = body["workshops"].first["tools"].map { |row| row["name"] }
    expect(tool_names).to contain_exactly("Planer", "Hidden Saw")
  end

  it "shows disabled shops and all hidden tools to admins" do
    sign_out member
    sign_in create(:member, :admin, :current)

    get "/api/workshops"

    body = JSON.parse(response.body)
    expect(body["canAddShop"]).to be(true)
    expect(body["workshops"].map { |row| row["name"] })
      .to contain_exactly("Closed Shop", "Wood Shop")
    woodshop = body["workshops"].find { |row| row["name"] == "Wood Shop" }
    expect(woodshop["tools"].map { |row| row["name"] })
      .to contain_exactly("Planer", "Hidden Saw", "Hidden Lathe")
  end

  it "only offers reservations when the current member meets resource prerequisites" do
    visible_tool.update!(reservable: true)

    get "/api/workshops"
    expect(JSON.parse(response.body).dig("workshops", 0, "reservationsAvailable"))
      .to be(false)

    create(:tool_checkout, member: member, tool: visible_tool)
    get "/api/workshops"
    expect(JSON.parse(response.body).dig("workshops", 0, "reservationsAvailable"))
      .to be(true)
  end
end
