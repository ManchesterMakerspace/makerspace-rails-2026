require "rails_helper"

RSpec.describe ReservationService do
  before do
    allow(REDIS).to receive(:set).and_return(true)
    allow(REDIS).to receive(:eval).and_return(1)
    ActiveJob::Base.queue_adapter = :test
  end

  let(:start_at) { 1.day.from_now.change(hour: 10, min: 0, sec: 0) }
  let(:end_at) { start_at + 1.hour }
  let(:shop) { create(:shop, reservable: false) }
  let(:tool) { create(:tool, shop: shop) }
  let(:member) { create(:member, :current) }
  let(:attributes) do
    {
      title: "Build project",
      shop_id: shop.id,
      reservation_scope: "tools",
      tool_ids: [tool.id.to_s],
      start_at: start_at,
      end_at: end_at
    }
  end

  it "always requires a checkout for the selected tool" do
    preview = described_class.preview(member: member, attributes: attributes)
    expect(preview[:eligible]).to be(false)
    expect(preview[:missingPrerequisites]).to include(hash_including(name: tool.name))
  end

  it "creates an approved reservation when eligibility and capacity are available" do
    create(:tool_checkout, member: member, tool: tool)
    reservation = described_class.create!(member: member, attributes: attributes)
    expect(reservation.status).to eq("approved")
    expect(reservation.tool_ids).to eq([tool.id.to_s])
  end

  it "marks cancellations as cancelled and no longer counts them against capacity" do
    create(:tool_checkout, member: member, tool: tool)
    existing = described_class.create!(member: member, attributes: attributes)

    described_class.cancel!(reservation: existing, actor: member)

    expect(existing.reload.status).to eq("cancelled")
    replacement = described_class.create!(
      member: create(:member, :current).tap { |other| create(:tool_checkout, member: other, tool: tool) },
      attributes: attributes
    )
    expect(replacement.status).to eq("approved")
  end

  it "rejects a reservation ending after prepaid membership expiration" do
    member.update!(expirationTime: (start_at + 30.minutes).to_i * 1000, subscription: false, subscription_id: nil)
    create(:tool_checkout, member: member, tool: tool)

    expect {
      described_class.create!(member: member, attributes: attributes)
    }.to raise_error(Error::UnprocessableEntity, /ends after your membership expires/)
  end

  it "caps the preview duration at the next capacity conflict" do
    create(:tool_checkout, member: member, tool: tool)
    create(
      :reservation,
      member: create(:member, :current),
      shop: shop,
      reservation_scope: "tools",
      tool_ids: [tool.id.to_s],
      start_at: start_at + 2.hours,
      end_at: start_at + 3.hours
    )

    preview = described_class.preview(member: member, attributes: attributes)

    expect(preview[:maximumDurationHours]).to eq(2.0)
  end

  it "makes a member's second overlapping reservation pending" do
    create(:tool_checkout, member: member, tool: tool)
    described_class.create!(member: member, attributes: attributes)
    other_tool = create(:tool, shop: create(:shop, reservable: false))
    create(:tool_checkout, member: member, tool: other_tool)

    second = described_class.create!(
      member: member,
      attributes: attributes.merge(shop_id: other_tool.shop_id, tool_ids: [other_tool.id.to_s])
    )
    expect(second.status).to eq("pending")
    expect(second.approval_reasons).to include("overlapping_member_reservation")
  end

  it "counts pending reservations against tool capacity" do
    create(:tool_checkout, member: member, tool: tool)
    create(:reservation, member: create(:member, :current), shop: shop,
      reservation_scope: "tools", tool_ids: [tool.id.to_s],
      start_at: start_at, end_at: end_at, status: "pending")

    expect {
      described_class.create!(member: member, attributes: attributes)
    }.to raise_error(Error::Conflict)
  end

  it "makes shop-wide and tool reservations mutually exclusive" do
    shop.update!(reservable: true)
    create(:tool_checkout, member: member, tool: tool)
    create(:reservation, member: create(:member, :current), shop: shop,
      reservation_scope: "shop", start_at: start_at, end_at: end_at)

    expect {
      described_class.create!(member: member, attributes: attributes)
    }.to raise_error(Error::Conflict)
  end

  it "treats legacy resources without a reservable field as not reservable" do
    id = BSON::ObjectId.new
    Shop.collection.insert_one(_id: id, name: "Legacy Shop")

    expect(Shop.find(id).reservable).to be(false)
  end

  it "requires half-hour increments for configured maximum duration" do
    tool.max_reservation_duration_hours = 1.25

    expect(tool).not_to be_valid
    expect(tool.errors[:max_reservation_duration_hours]).to be_present
  end

  it "rejects reservation prerequisites from another shop" do
    outside_tool = create(:tool, shop: create(:shop))
    tool.reservation_prerequisite_tool_ids = [outside_tool.id.to_s]

    expect(tool).not_to be_valid
    expect(tool.errors[:reservation_prerequisite_tool_ids]).to be_present
  end

  it "enforces selected same-shop prerequisites for a shop reservation" do
    shop.update!(
      reservable: true,
      reservation_prerequisite_tool_ids: [tool.id.to_s]
    )

    preview = described_class.preview(
      member: member,
      attributes: attributes.merge(
        reservation_scope: "shop",
        tool_ids: []
      )
    )

    expect(preview[:eligible]).to be(false)
    expect(preview[:missingPrerequisites]).to include(hash_including(name: tool.name))
  end

  it "cancels current and future reservations when membership is revoked" do
    current_reservation = create(
      :reservation,
      member: member,
      shop: shop,
      start_at: 1.hour.ago,
      end_at: 1.hour.from_now
    )
    future_reservation = create(:reservation, member: member, shop: shop)
    past_reservation = create(
      :reservation,
      member: member,
      shop: shop,
      start_at: 2.hours.ago,
      end_at: 1.hour.ago
    )

    member.update!(status: "revoked")

    expect(current_reservation.reload.status).to eq("cancelled")
    expect(future_reservation.reload.status).to eq("cancelled")
    expect(past_reservation.reload.status).to eq("approved")
  end

  it "cancels reservations beyond the paid-through date when recurring membership ends" do
    member.update!(subscription: true, subscription_id: "subscription-1")
    within_membership = create(
      :reservation,
      member: member,
      shop: shop,
      start_at: 1.day.from_now,
      end_at: 2.days.from_now
    )
    beyond_membership = create(
      :reservation,
      member: member,
      shop: shop,
      start_at: 19.days.from_now,
      end_at: 21.days.from_now
    )

    member.update!(subscription: false, subscription_id: nil)

    expect(within_membership.reload.status).to eq("approved")
    expect(beyond_membership.reload.status).to eq("cancelled")
  end
end
