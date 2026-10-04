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

  it 'retires only open requests for destroyed groups and preserves request history' do
    shop = create(:shop)
    included = create(:tool, shop: shop)
    member = create(:member, :current)
    ToolCheckout.create!(member: member, tool: included, defer_users_channel_invitation: true, defer_group_callbacks: true)
    groups = [false, true].map do |archived|
      ToolGroup.create!(shop: shop, name: "Kit #{archived}", archived: archived, included_tool_ids: [included.id.to_s])
    end
    checkout_requests = groups.map { |group| ToolCheckoutRequest.create!(member: member, tool_group: group) }
    closed_checkout = ToolCheckoutRequest.create!(member: member, tool_group: groups.first, status: 'closed')
    approved_volunteer = CheckoutApproverRequest.create!(member: member, tool_group: groups.first, status: 'approved')
    volunteer_requests = groups.map { |group| CheckoutApproverRequest.create!(member: member, tool_group: group) }
    other_tool = create(:tool)
    other_group = ToolGroup.create!(shop: other_tool.shop, name: 'Other kit', included_tool_ids: [other_tool.id.to_s])
    ToolCheckout.create!(member: member, tool: other_tool, defer_users_channel_invitation: true, defer_group_callbacks: true)
    other_checkout = ToolCheckoutRequest.create!(member: member, tool_group: other_group)
    other_volunteer = CheckoutApproverRequest.create!(member: member, tool_group: other_group)

    shop.destroy!

    expect(checkout_requests.map { |request| request.reload.status }).to eq(%w[deleted deleted])
    expect(volunteer_requests.map { |request| request.reload.status }).to eq(%w[revoked revoked])
    expect(closed_checkout.reload.status).to eq('closed')
    expect(approved_volunteer.reload.status).to eq('approved')
    expect(other_checkout.reload.status).to eq('open')
    expect(other_volunteer.reload.status).to eq('open')
    expect(ToolGroup.where(:id.in => groups.map(&:id))).not_to exist
  end
end
