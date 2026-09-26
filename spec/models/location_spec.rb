require 'rails_helper'

RSpec.describe Location, type: :model do
  describe "Mongoid validations" do
    it { is_expected.to be_mongoid_document }
    it { is_expected.to be_stored_in(collection: 'locations') }

    it { is_expected.to have_field(:name).of_type(String) }
    it { is_expected.to have_field(:kind).of_type(String) }
    it { is_expected.to have_field(:parent_id).of_type(BSON::ObjectId) }
    it { is_expected.to have_field(:svg_element_id).of_type(String) }
    it { is_expected.to have_field(:x_pct).of_type(Float) }
    it { is_expected.to have_field(:y_pct).of_type(Float) }
  end

  describe "ActiveModel validations" do
    it { is_expected.to validate_presence_of(:name) }
    it { is_expected.to belong_to(:shop) }
  end

  it "has a valid factory" do
    expect(build(:location)).to be_valid
  end

  context "public methods" do
    it "finds its parent" do
      shop = create(:shop)
      parent = create(:location, shop: shop)
      child = create(:location, shop: shop, parent_id: parent.id)

      expect(child.parent).to eq(parent)
    end

    it "returns nil for parent when there is none" do
      expect(build(:location).parent).to be_nil
    end

    it "finds its children" do
      shop = create(:shop)
      parent = create(:location, shop: shop)
      child = create(:location, shop: shop, parent_id: parent.id)
      create(:location, shop: shop) # unrelated sibling location

      expect(parent.children.to_a).to eq([child])
    end

    it "is invalid when its parent belongs to a different shop" do
      other_shop_parent = create(:location, shop: create(:shop))
      child = build(:location, shop: create(:shop), parent_id: other_shop_parent.id)

      expect(child).not_to be_valid
      expect(child.errors[:parent_id]).to include("must belong to the same shop")
    end

    it "is valid when its parent belongs to the same shop" do
      shop = create(:shop)
      parent = create(:location, shop: shop)
      child = build(:location, shop: shop, parent_id: parent.id)

      expect(child).to be_valid
    end
  end
end
