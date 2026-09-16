require "rails_helper"

RSpec.describe SlackCheckoutRequestModal do
  let(:shop) { create(:shop) }
  let(:member) { create(:member, :current) }

  def options(view)
    view[:blocks].find { |block| block[:block_id] == "tool" }[:element][:options]
  end

  it "uses IDs for values and sorted, 75-character labels" do
    zulu = create(:tool, shop: shop, name: "Zulu")
    alpha = create(:tool, shop: shop, name: "A" * 80)
    result = options(described_class.build(shop, member))

    expect(result.pluck(:value)).to eq([alpha.id.to_s, zulu.id.to_s])
    expect(result.first.dig(:text, :text)).to eq("A" * 75)
  end

  it "includes an optional 128-character note" do
    create(:tool, shop: shop)
    view = described_class.build(shop, member)
    note = view[:blocks].find { |block| block[:block_id] == "note" }

    expect(note).to include(optional: true)
    expect(note.dig(:element, :max_length)).to eq(128)
  end

  it "supports exactly 100 eligible options" do
    100.times { |index| create(:tool, shop: shop, name: format("Tool %03d", index)) }
    expect(options(described_class.build(shop, member)).length).to eq(100)
  end

  it "provides a clear portal fallback above Slack's 100-option limit" do
    101.times { |index| create(:tool, shop: shop, name: format("Tool %03d", index)) }
    expect { described_class.build(shop, member) }
      .to raise_error(Error::UnprocessableEntity, /More than 100.*Member Portal/)
  end

  it "includes and marks tools with an existing open request without offering them as options" do
    requested = create(:tool, shop: shop, name: "Bandsaw")
    eligible = create(:tool, shop: shop, name: "Lathe")
    ToolCheckoutRequest.create!(member: member, tool: requested, status: "open")

    view = described_class.build(shop, member)
    notice = view[:blocks].find { |block| block[:type] == "section" }
    expect(notice.dig(:text, :text)).to include("Bandsaw", "request open")
    expect(options(view).pluck(:value)).to eq([eligible.id.to_s])
  end
end
