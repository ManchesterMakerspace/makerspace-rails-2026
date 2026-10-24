require "rails_helper"

# activeRentals is staff information (same audience as provisioning): admins and board see
# which rentals are still active on a member's profile, the member and others do not (#276).
RSpec.describe "Member active rentals", type: :request do
  let(:admin) { create(:member, :current, :admin) }
  let(:board) { create(:member, :current, role: "board_member") }
  let(:member) { create(:member, :current) }

  before do
    allow(REDIS).to receive(:set).and_return(true)
    create(:rental, member: member, number: "BS-Tote-3", description: "Black Tote", subscription_id: "sub-1")
    create(:rental, member: member, number: "Shelf-9", description: "Full Shelf", status: "vacating")
  end

  def profile_as(viewer, target = member)
    sign_in viewer
    get "/api/members/#{target.id}"
    JSON.parse(response.body)
  end

  it "lists only the active rentals, with billing, for an admin" do
    rentals = profile_as(admin)["activeRentals"]

    expect(rentals.map { |rental| rental["number"] }).to eq(["BS-Tote-3"])
    expect(rentals.first).to include("description" => "BS-Tote-3 (Black Tote)", "billing" => true)
  end

  it "is returned to a board member" do
    expect(profile_as(board)["activeRentals"].size).to eq(1)
  end

  it "is not returned to the member themselves" do
    expect(profile_as(member)).not_to have_key("activeRentals")
  end
end
