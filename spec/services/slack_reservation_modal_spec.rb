require "rails_helper"

RSpec.describe SlackReservationModal do
  let(:member) { instance_double(Member, id: BSON::ObjectId.new, status: "activeMember") }
  let(:tools) { [] }
  let(:prerequisite_tools) { [] }
  let(:relation) { double("reservable tool relation") }
  let(:prerequisite_relation) { double("prerequisite relation", to_a: prerequisite_tools) }
  let(:shop) { resource_double(Shop, name: "Woodshop", reservable: true) }

  before do
    allow(Tool).to receive(:where) do |criteria|
      criteria.key?(:reservable) ? relation : prerequisite_relation
    end
    allow(relation).to receive(:order_by).with(name: :asc).and_return(relation)
    allow(relation).to receive(:to_a).and_return(tools)
  end

  def resource_double(klass, overrides = {})
    defaults = {
      id: BSON::ObjectId.new,
      name: klass == Shop ? "Woodshop" : "Tool",
      reservable: true,
      reservation_horizon_days: 7,
      minimum_advance_notice_hours: 2,
      prohibit_same_day_reservations: false,
      max_reservation_duration_hours: 8.0,
      reservation_full_day: false,
      reservation_requires_approval: false,
      reservation_prerequisite_tool_ids: []
    }
    defaults.merge!(effective_reservation_prerequisite_ids: [], allow_pending: false) if klass == Tool
    instance_double(klass, **defaults.merge(overrides))
  end

  def block(view, block_id)
    view[:blocks].find { |candidate| candidate[:block_id] == block_id }
  end

  def policy_text(view)
    block(view, "reservation_policy").dig(:text, :text)
  end

  def duration_values(view)
    block(view, "duration").dig(:element, :options).pluck(:value)
  end

  it "builds a shop-only view with Duration and an informational policy alert" do
    view = described_class.build(shop, member)

    expect(block(view, "scope")[:element][:options]).to contain_exactly(hash_including(value: "shop"))
    expect(block(view, "tools")).to be_nil
    expect(block(view, "end_time")).to be_nil
    expect(block(view, "duration")).to be_present
    expect(block(view, "reservation_policy")).to include(type: "alert", level: "info")
    expect(block(view, "scope")).to include(dispatch_action: true)
    expect(block(view, "scope").dig(:element, :action_id)).to eq("reservation_scope_changed")
  end

  it "builds a tool-only view and selects its first tool" do
    allow(shop).to receive(:reservable).and_return(false)
    tools << resource_double(Tool, name: "Bandsaw")

    view = described_class.build(shop, member)

    expect(block(view, "scope")[:element][:options]).to contain_exactly(hash_including(value: "tools"))
    expect(block(view, "tools")[:element][:initial_options]).to contain_exactly(hash_including(value: tools.first.id.to_s))
    expect(policy_text(view)).to include("Bandsaw")
  end

  it "supports mixed scope and applies selected-tool policies" do
    tools << resource_double(Tool, name: "Lathe", reservation_horizon_days: 3)

    shop_view = described_class.build(shop, member)
    tool_view = described_class.build(shop, member, reservation_scope: "tools", tool_ids: [tools.first.id])

    expect(block(shop_view, "scope")[:element][:options].pluck(:value)).to eq(%w[shop tools])
    expect(policy_text(shop_view)).to include("Woodshop")
    expect(policy_text(tool_view)).to include("Lathe", "3 days")
  end

  it "preserves entered state when rebuilding a view" do
    tools << resource_double(Tool, name: "Lathe")

    view = described_class.update(
      shop: shop, member: member, response_url: "https://example.test/response",
      slack_user_id: "U123", reservation_scope: "tools", tool_ids: [tools.first.id],
      title: "Careful setup", date: "2026-10-02", start_time: "14:30", duration: "hours:2.5"
    )

    expect(block(view, "title").dig(:element, :initial_value)).to eq("Careful setup")
    expect(block(view, "date").dig(:element, :initial_date)).to eq("2026-10-02")
    expect(block(view, "start_time").dig(:element, :initial_time)).to eq("14:30")
    expect(block(view, "duration").dig(:element, :initial_option, :value)).to eq("hours:2.5")
    expect(block(view, "tools")).to include(dispatch_action: true)
    expect(block(view, "tools").dig(:element, :action_id)).to eq("reservation_tools_changed")
  end

  it "clamps a preserved duration to the greatest newly valid choice" do
    allow(shop).to receive(:max_reservation_duration_hours).and_return(4.0)

    view = described_class.build(shop, member, duration: "hours:8")

    expect(block(view, "duration").dig(:element, :initial_option, :value)).to eq("hours:4.0")
  end

  it "omits submission for incompatible multi-tool notice and horizon policies" do
    tools.concat([
      resource_double(Tool, name: "Immediate Window", reservation_horizon_days: 0),
      resource_double(Tool, name: "No Same Day", prohibit_same_day_reservations: true)
    ])

    view = described_class.build(
      shop, member, reservation_scope: "tools", tool_ids: tools.map(&:id)
    )

    expect(view).not_to have_key(:submit)
    expect(block(view, "duration")).to be_nil
    expect(policy_text(view)).to include(
      "Unavailable combination", "Immediate Window", "No Same Day", "cannot be reserved together"
    )
  end

  it "explains when full-day and maximum-duration rules leave no valid duration" do
    tools.concat([
      resource_double(Tool, name: "Kiln", reservation_full_day: true,
        max_reservation_duration_hours: 24),
      resource_double(Tool, name: "Short Session", max_reservation_duration_hours: 8)
    ])

    view = described_class.build(
      shop, member, reservation_scope: "tools", tool_ids: tools.map(&:id)
    )

    expect(view).not_to have_key(:submit)
    expect(policy_text(view)).to include("No duration is valid", "Kiln", "Short Session")
  end

  it "offers half-hour choices through five hours and whole-hour choices beyond" do
    allow(shop).to receive(:max_reservation_duration_hours).and_return(8.0)

    expect(duration_values(described_class.build(shop, member))).to eq(
      %w[hours:0.5 hours:1.0 hours:1.5 hours:2.0 hours:2.5 hours:3.0 hours:3.5 hours:4.0 hours:4.5 hours:5.0 hours:6 hours:7 hours:8]
    )
  end

  it "offers whole-day choices and removes the start-time input for full-day resources" do
    allow(shop).to receive_messages(reservation_full_day: true, max_reservation_duration_hours: 72.0)

    view = described_class.build(shop, member)

    expect(duration_values(view)).to eq(%w[days:1 days:2 days:3])
    expect(block(view, "start_time")).to be_nil
    expect(policy_text(view)).to include("whole days", "3 days")
  end

  it "summarizes approval, notice, horizon, same-day, and prerequisite rules" do
    prerequisite = resource_double(Tool, name: "Safety Orientation")
    prerequisite_tools << prerequisite
    allow(shop).to receive_messages(
      reservation_requires_approval: true,
      minimum_advance_notice_hours: 6.0,
      reservation_horizon_days: 2,
      prohibit_same_day_reservations: true,
      reservation_prerequisite_tool_ids: [prerequisite.id.to_s]
    )

    text = policy_text(described_class.build(shop, member))

    expect(text).to include("Manager approval", "6 hours", "2 days", "Same-day", "Safety Orientation")
  end

  it "uses strictest selected rules and names resources when their rules differ" do
    tools.concat([
      resource_double(Tool, name: "Lathe", reservation_horizon_days: 10,
        minimum_advance_notice_hours: 2, max_reservation_duration_hours: 8),
      resource_double(Tool, name: "Mill", reservation_horizon_days: 3,
        minimum_advance_notice_hours: 6, max_reservation_duration_hours: 4)
    ])

    view = described_class.build(
      shop, member, reservation_scope: "tools", tool_ids: tools.map(&:id)
    )
    text = policy_text(view)

    expect(duration_values(view).last).to eq("hours:4.0")
    expect(text).to include("3 days", "6 hours", "Maximum duration: 4 hours", "Lathe", "Mill", "Rules differ")
  end

  it "rejects more than 100 reservable tools" do
    tools.concat(101.times.map { |index| resource_double(Tool, name: "Tool #{index}") })

    expect { described_class.build(shop, member) }
      .to raise_error(Error::UnprocessableEntity, "This shop has more than 100 reservable tools; use the portal")
  end
end
