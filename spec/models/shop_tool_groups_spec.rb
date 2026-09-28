require 'rails_helper'

RSpec.describe Shop do
  it 'destroys active and archived groups before their included and prerequisite tools' do
    shop = create(:shop)
    unrelated = create(:tool, shop: shop)
    included = create(:tool, shop: shop)
    prerequisite = create(:tool, shop: shop)
    groups = [false, true].map do |archived|
      ToolGroup.create!(shop: shop, name: "Kit #{archived}", archived: archived,
        included_tool_ids: [included.id.to_s], prerequisite_ids: [prerequisite.id.to_s])
    end
    other_shop = create(:shop)
    other_tool = create(:tool, shop: other_shop)
    survivor = ToolGroup.create!(shop: other_shop, name: 'Other kit', included_tool_ids: [other_tool.id.to_s])

    expect { included.destroy }.to raise_error(Error::Conflict)
    expect { shop.destroy }.not_to raise_error
    expect(Shop.where(id: shop.id)).not_to exist
    expect(Tool.where(:id.in => [unrelated.id, included.id, prerequisite.id])).not_to exist
    expect(ToolGroup.where(:id.in => groups.map(&:id))).not_to exist
    expect(survivor.reload).to be_persisted
    expect(other_tool.reload).to be_persisted
  end
end
