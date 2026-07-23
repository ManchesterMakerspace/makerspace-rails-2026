require "rails_helper"

RSpec.describe Service::ReservationCalendar do
  let(:member) { create(:member, :current, email: "member@example.com") }
  let(:shop) do
    create(
      :shop,
      name: "Woodshop",
      color_id: "7",
      resource_email: "woodshop-resource@example.com"
    )
  end
  let(:tool) do
    create(
      :tool,
      shop: shop,
      name: "Planer",
      resource_email: "planer-resource@example.com"
    )
  end
  let(:reservation) do
    create(
      :reservation,
      member: member,
      shop: shop,
      reservation_scope: "tools",
      tool_ids: [tool.id.to_s]
    )
  end

  it "adds the shop color, shop label, owner attendee, and tool-in-shop description" do
    create(:mailtrap_event, member: member, email: member.email, status: "delivery")

    event = described_class.send(:build_event, reservation)

    expect(event.color_id).to eq("7")
    expect(event.event_label_id).to eq(Service::GoogleWorkspace.label_id_for(shop.id))
    expect(event.description).to include("Resources: Planer in Woodshop")
    expect(event.extended_properties.private["makerspace_shop_id"]).to eq(shop.id.to_s)
    expect(event.attendees).to include(
      have_attributes(email: tool.resource_email, resource: true),
      have_attributes(email: member.email)
    )
  end

  it "does not invite an owner whose latest delivery status is undeliverable" do
    create(:mailtrap_event, member: member, email: member.email, status: "bounce")

    event = described_class.send(:build_event, reservation)

    expect(event.attendees.map(&:email)).not_to include(member.email)
  end

  it "derives a stable UUID label ID from the Mongo ObjectID" do
    first = Service::GoogleWorkspace.label_id_for(shop.id)
    second = Service::GoogleWorkspace.label_id_for(shop.id)

    expect(first).to eq(second)
    expect(first).to match(
      /\A[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
    )
  end
end
