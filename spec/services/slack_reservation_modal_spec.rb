require "rails_helper"

RSpec.describe SlackReservationModal do
  let(:shop) { instance_double(Shop, id: BSON::ObjectId.new, name: "Woodshop", reservable: shop_reservable) }
  let(:member) { instance_double(Member, id: BSON::ObjectId.new) }
  let(:relation) { double("tool relation") }

  before do
    allow(Tool).to receive(:where).with(
      shop_id: shop.id,
      reservable: true,
      :disabled.ne => true
    ).and_return(relation)
    allow(relation).to receive(:order_by).with(name: :asc).and_return(relation)
    allow(relation).to receive(:to_a).and_return(tools)
  end

  def block(view, block_id)
    view[:blocks].find { |candidate| candidate[:block_id] == block_id }
  end

  context "with a reservable shop and no reservable tools" do
    let(:shop_reservable) { true }
    let(:tools) { [] }

    it "builds a shop-only modal without an empty tools selector" do
      view = described_class.build(shop, member)

      expect(block(view, "scope")[:element][:options]).to contain_exactly(
        hash_including(value: "shop")
      )
      expect(block(view, "tools")).to be_nil
    end
  end

  context "with a non-reservable shop and reservable tools" do
    let(:shop_reservable) { false }
    let(:tools) { [instance_double(Tool, id: BSON::ObjectId.new, name: "Bandsaw")] }

    it "builds a tool-only modal" do
      view = described_class.build(shop, member)

      expect(block(view, "scope")[:element][:options]).to contain_exactly(
        hash_including(value: "tools")
      )
      expect(block(view, "tools")[:element][:options]).to contain_exactly(
        hash_including(value: tools.first.id.to_s)
      )
    end
  end

  context "with a reservable shop and reservable tools" do
    let(:shop_reservable) { true }
    let(:tools) { [instance_double(Tool, id: BSON::ObjectId.new, name: "Lathe")] }

    it "offers both reservation scopes and includes the tools selector" do
      view = described_class.build(shop, member)

      expect(block(view, "scope")[:element][:options].pluck(:value)).to eq(%w[shop tools])
      expect(block(view, "tools")[:element][:options]).to contain_exactly(
        hash_including(value: tools.first.id.to_s)
      )
    end
  end

  context "with more than 100 reservable tools" do
    let(:shop_reservable) { true }
    let(:tools) do
      101.times.map do |index|
        instance_double(Tool, id: BSON::ObjectId.new, name: "Tool #{index}")
      end
    end

    it "rejects the modal in favor of the portal" do
      expect { described_class.build(shop, member) }
        .to raise_error(Error::UnprocessableEntity, "This shop has more than 100 reservable tools; use the portal")
    end
  end
end
