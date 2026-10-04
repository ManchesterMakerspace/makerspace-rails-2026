require 'rails_helper'

RSpec.describe ToolGroupCatalog do
  let(:shop) { create(:shop) }
  let(:tool) { create(:tool, shop: shop) }
  let(:actor) { create(:member, :current, :admin) }
  let(:group) { ToolGroup.create!(shop: shop, name: 'Kit', included_tool_ids: [tool.id.to_s]) }
  before do
    allow(REDIS).to receive(:set).and_return(true)
    allow(REDIS).to receive(:eval).and_return(1)
  end
  it 'extends individual authority but never grants existing trainees new checkouts' do
    trainee = create(:member, :current)
    ToolCheckout.create!(member: trainee, tool: tool, defer_users_channel_invitation: true)
    approver = CheckoutApprover.create!(member: actor, tool_group_ids: [group.id.to_s])
    extra = create(:tool, shop: shop)
    allow(CheckoutApproverMutationLock).to receive(:with).with(member_id: actor.id.to_s).and_wrap_original do |lock, **args, &operation|
      lock.call(**args) do
        operation.call
        expect(group.reload.revision).to eq(2)
        expect(approver.reload.tool_ids).to include(extra.id.to_s)
      end
    end
    described_class.save!(actor: actor, group: group, revision: 1, attributes: { included_tool_ids: [tool.id.to_s, extra.id.to_s] })
    expect(approver.reload.tool_ids).to contain_exactly(tool.id.to_s, extra.id.to_s)
    expect(ToolCheckout.where(member: trainee, tool: extra)).not_to exist
    approver.update!(tool_group_ids: [], tool_ids: [])
    expect(approver.reload.tool_ids).to contain_exactly(tool.id.to_s, extra.id.to_s)
  end
  it 'archives open requests and retains individual grants' do
    member = create(:member, :current)
    request = ToolCheckoutRequest.create!(member: member, tool_group: group)
    ToolCheckout.create!(member: member, tool: tool, defer_users_channel_invitation: true, defer_group_callbacks: true)
    volunteer = CheckoutApproverRequest.create!(member: member, tool_group: group)
    approver = CheckoutApprover.create!(member: actor, tool_group_ids: [group.id.to_s])
    described_class.save!(actor: actor, group: group, revision: 1, attributes: { archived: true })
    expect(request.reload.status).to eq('deleted')
    expect(volunteer.reload.status).to eq('revoked')
    expect(approver.reload.tool_ids).to include(tool.id.to_s)
    expect(approver.tool_group_ids).to be_empty
    expect(group.reload.revision).to eq(2)
  end
  it 'rejects a resource manager assigned only to another shop' do
    actor.update!(role: 'resource_manager', resource_manager_shop_ids: [create(:shop).id.to_s])
    expect { described_class.save!(actor: actor, group: group, revision: 1, attributes: { name: 'Other' }) }.to raise_error(Error::Forbidden)
  end
  it 'rechecks revocation after locking and holds the approver lock through commit' do
    approver = CheckoutApprover.create!(member: actor, tool_group_ids: [group.id.to_s])
    extra = create(:tool, shop: shop)
    checkout = ToolCheckout.create!(member: actor, tool: extra, defer_users_channel_invitation: true)
    allow(CheckoutApproverMutationLock).to receive(:with).with(member_id: actor.id.to_s) do |&operation|
      # A revocation wins immediately before the catalog acquires this lock.
      checkout.approver_mutation_lock_held = true
      checkout.update!(revoked_at: Time.current, revocation_reason: 'Revoked')
      operation.call
      # Read independently of the transaction before releasing the lock.
      expect(group.reload.revision).to eq(2)
    end
    described_class.save!(actor: actor, group: group, revision: 1,
      attributes: { included_tool_ids: [tool.id.to_s, extra.id.to_s] })
    expect(CheckoutApproverMutationLock).to have_received(:with).with(member_id: actor.id.to_s)
    expect(approver.reload.tool_group_ids).to be_empty
    expect(approver.tool_ids).not_to include(extra.id.to_s)
    expect(approver.group_granted_tool_ids).not_to include(extra.id.to_s)
  end

end
