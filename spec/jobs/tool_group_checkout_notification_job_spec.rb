require 'rails_helper'

RSpec.describe ToolGroupCheckoutNotificationJob do
  let(:shop) { create(:shop) }
  let(:tool) { create(:tool, shop: shop) }
  let(:group) { ToolGroup.create!(shop: shop, name: 'Kit', included_tool_ids: [tool.id.to_s]) }
  let(:actor) { create(:member, :current, :admin) }
  let(:member) { create(:member, :current) }
  before do
    allow(REDIS).to receive(:set).and_return(true)
    allow(REDIS).to receive(:eval).and_return(1)
    allow(ToolGroupCheckout).to receive(:notify)
    allow_any_instance_of(ToolCheckoutRequest).to receive(:refresh_closed_announcement)
    allow(described_class).to receive(:perform_later).and_return(true)
  end

  it 'queues only committed IDs, then delivers the batch and reconciled announcements in the job' do
    request = ToolCheckoutRequest.create!(member: member, tool: tool)
    result = ToolGroupCheckout.approve!(actor: actor, member: member, group: group, revision: group.revision, source: 'slack')
    expect(request.reload.status).to eq('closed')
    expect(ToolGroupCheckout).not_to have_received(:notify)
    args = [group.id.to_s, member.id.to_s, result[:checkouts].map { |row| row.id.to_s }, [request.id.to_s], result[:approval_batch_id], result[:notification_snapshot]]
    expect(described_class).to have_received(:perform_later).with(*args)
    expect_any_instance_of(ToolCheckoutRequest).to receive(:refresh_closed_announcement)
    described_class.perform_now(*args)
    expect(ToolGroupCheckout).to have_received(:notify).with(nil, member, hash_including(approval_batch_id: result[:approval_batch_id]))
    ToolGroupCheckout.approve!(actor: actor, member: member, group: group, revision: group.revision, source: 'slack')
    expect(described_class).to have_received(:perform_later).once
  end

  it 'queues closed announcements when an all-held group request is resolved' do
    request = ToolCheckoutRequest.create!(member: member, tool_group: group)
    ToolCheckout.create!(member: member, tool: tool, defer_users_channel_invitation: true, defer_group_callbacks: true)
    result = ToolGroupCheckout.approve!(actor: actor, member: member, group: group,
      revision: group.revision, source: 'slack', request_id: request.id)
    expect(result[:checkouts]).to be_empty
    expect(described_class).to have_received(:perform_later).with(group.id.to_s, member.id.to_s, [], [request.id.to_s], nil, result[:notification_snapshot])
    expect_any_instance_of(ToolCheckoutRequest).to receive(:refresh_closed_announcement)
    described_class.perform_now(group.id.to_s, member.id.to_s, [], [request.id.to_s], nil, result[:notification_snapshot])
    expect(ToolGroupCheckout).not_to have_received(:notify)
  end

  it 'delivers the approved catalog snapshot even after group and child edits' do
    SlackUser.create!(member: member, slack_id: 'UMEMBER')
    tool.update!(users_channel: 'COLD', wiki_url: 'https://old.example.test')
    group.update!(announce: true, announce_channel: 'CANNOUNCE')
    args = nil
    allow(described_class).to receive(:perform_later) { |*values| args = values; true }
    result = ToolGroupCheckout.approve!(actor: actor, member: member, group: group, revision: group.revision, source: 'slack')
    snapshot = result[:notification_snapshot]
    group.set(name: 'Changed kit', revision: 99, included_tool_ids: [], announce_channel: 'CNEW')
    tool.set(name: 'Changed tool', users_channel: 'CNEW', wiki_url: 'https://new.example.test')
    allow(ToolGroupCheckout).to receive(:notify).and_call_original
    allow(Service::AuditLogger).to receive(:log)
    allow(Service::SlackConnector).to receive(:channel_member?).and_return(false)
    allow(Service::SlackConnector).to receive(:invite_to_channel)
    allow(Service::SlackConnector).to receive(:send_slack_message)
    allow(ToolCheckoutSlackCanvasSyncJob).to receive(:perform_later)
    described_class.perform_now(*ActiveJob::Arguments.deserialize(ActiveJob::Arguments.serialize(args)))
    expect(Service::AuditLogger).to have_received(:log).with(hash_including(
      after_snapshot: hash_including(group_revision: snapshot['revision'], included_tool_ids: [tool.id.to_s])))
    expect(Service::SlackConnector).to have_received(:invite_to_channel).with(snapshot['tools'].first['users_channel'], 'UMEMBER')
    expect(Service::SlackConnector).to have_received(:send_slack_message).with(include('*Kit*'), snapshot['channel'])
    expect(Service::SlackConnector).to have_received(:send_slack_message).with(include('https://old.example.test'), 'UMEMBER')
    expect(Service::SlackConnector).not_to have_received(:send_slack_message).with(anything, 'CNEW')
  end

  it 'does not enqueue a rolled-back approval' do
    expect { ToolGroupCheckout.approve!(actor: actor, member: member, group: group, revision: 0, source: 'slack') }.to raise_error(Error::Conflict)
    expect(described_class).not_to have_received(:perform_later)
  end

  it 'keeps committed approvals successful if enqueue fails without falling back to synchronous delivery' do
    allow(described_class).to receive(:perform_later).and_raise('Queue unavailable')
    allow(Service::ErrorReporter).to receive(:notify)
    result = ToolGroupCheckout.approve!(actor: actor, member: member, group: group, revision: group.revision, source: 'slack')
    expect(result[:checkouts].first.reload).to be_persisted
    expect(ToolGroupCheckout).not_to have_received(:notify)
    expect(Service::ErrorReporter).to have_received(:notify).with('Checkout notification failed', context: { error_class: 'RuntimeError' })
  end

  it 'queues notifications from the stateful Slack request approval workflow' do
    SlackUser.create!(member: actor, slack_id: 'UAPPROVER')
    request = ToolCheckoutRequest.create!(member: member, tool_group: group)
    metadata = SlackCheckoutModal.encode_metadata('member_id' => actor.id.to_s, 'shop_id' => shop.id.to_s,
      'slack_user_id' => 'UAPPROVER', 'step' => 'request_approve', 'record_id' => request.id.to_s, 'group_revision' => group.revision)
    SlackCheckoutWorkflow.new('type' => 'view_submission', 'user' => { 'id' => 'UAPPROVER' },
      'view' => { 'private_metadata' => metadata }).call
    expect(request.reload.status).to eq('closed')
    expect(described_class).to have_received(:perform_later).once
    expect(ToolGroupCheckout).not_to have_received(:notify)
  end
end
