require 'rails_helper'

if ENV['RUN_OPTIONAL_SLACK_CHECKOUT_SPECS'] == 'true'
  RSpec.describe SlackCheckoutRequestJob do
    let(:shop) { create(:shop, slack_channel: 'woodshop') }
    let(:member) { create(:member, :current) }
    let(:tool) { create(:tool, shop: shop, notes: 'Combo: 4-5-6') }
    let!(:slack_user) { SlackUser.create!(member: member, slack_id: 'U123', slack_email: member.email) }
    let(:posted_bodies) { [] }

    before do
      allow(::Service::SlackConnector).to receive(:send_slack_message)
      allow(REDIS).to receive(:set).and_return(true)
      allow(REDIS).to receive(:eval).and_return(1)

      allow(SlackCheckoutOutcomeJob).to receive(:enqueue) do |text, _url, _user|
        posted_bodies << { "text" => text, "response_type" => "ephemeral", "replace_original" => true }
      end
    end

    def perform(tool_name, channel_name: shop.slack_channel, channel_id: nil)
      described_class.perform_now(
        'response_url' => 'https://example.test/response',
        'user_id' => 'U123',
        'tool_name' => tool_name,
        'channel_name' => channel_name,
        'channel_id' => channel_id
      )
    end

    it 'rejects open tools without creating requests' do
      tool.update!(open: true)
      expect { perform(tool.name) }.not_to change { ToolCheckoutRequest.count }
      expect(posted_bodies.last['text']).to include('No checkout required')
    end

    it 'rejects tools in hidden shops' do
      tool.name
      shop.update!(disabled: true)
      expect { perform(tool.name) }.not_to change { ToolCheckoutRequest.count }
    end

    it 'lists eligible tools when no tool name is given' do
      tool_name = tool.name # force creation before the job queries for eligible tools
      perform(nil)

      expect(posted_bodies.last['text']).to include(tool_name)
    end

    it 'creates a new open checkout request for an eligible tool the member does not already have' do
      expect {
        perform(tool.name)
      }.to change { ToolCheckoutRequest.where(member_id: member.id, tool_id: tool.id, status: 'open').count }.by(1)
      expect(posted_bodies.last['text']).to include('Requested checkout')
    end

    it 'requires an exact tool name when another tool contains the requested name' do
      create(:tool, shop: shop, name: 'Bandsaw')
      create(:tool, shop: shop, name: 'Saw')

      expect { perform('band') }.not_to change(ToolCheckoutRequest, :count)
      expect(posted_bodies.last['text']).to include("No eligible tool matching 'band'")

      expect { perform('sAw') }.to change(ToolCheckoutRequest, :count).by(1)
      expect(ToolCheckoutRequest.last.tool.name).to eq('Saw')
    end

    describe 'a member who already holds the tool (#402)' do
      before { create(:tool_checkout, member: member, tool: tool) }

      it 'creates no request and re-sends the notes by DM' do
        expect(::Service::SlackConnector).to receive(:send_slack_message)
          .with(a_string_including('Notes for', tool.name, 'Combo: 4-5-6'), 'U123')

        expect { perform(tool.name) }.not_to change { ToolCheckoutRequest.count }

        expect(posted_bodies.last['text']).to include("already checked out on *#{tool.name}*", 'notes re-sent via DM')
      end

      it 'says only that they are checked out when the tool has no notes' do
        tool.update!(notes: nil)
        expect(::Service::SlackConnector).not_to receive(:send_slack_message)

        expect { perform(tool.name) }.not_to change { ToolCheckoutRequest.count }

        expect(posted_bodies.last['text']).to include('already checked out')
        expect(posted_bodies.last['text']).not_to include('re-sent')
      end

      it 'does not claim the notes were sent when the member cannot be messaged' do
        allow_any_instance_of(Member).to receive(:direct_notifications_suppressed?).and_return(true)
        expect(::Service::SlackConnector).not_to receive(:send_slack_message)

        expect { perform(tool.name) }.not_to change { ToolCheckoutRequest.count }

        expect(posted_bodies.last['text']).to include('could not be sent by DM')
        expect(posted_bodies.last['text']).not_to include('re-sent')
      end

      it 'matches the tool name case-insensitively like any other request' do
        expect(::Service::SlackConnector).to receive(:send_slack_message).with(a_string_including('Combo: 4-5-6'), 'U123')

        perform(tool.name.upcase)

        expect(posted_bodies.last['text']).to include('notes re-sent via DM')
      end
    end

    it 'does not resend notes for an expired checkout; it goes through the normal request path' do
      create(:tool_checkout, member: member, tool: tool, expires_on: Date.current - 3)
      expect(::Service::SlackConnector).not_to receive(:send_slack_message).with(a_string_including('Notes for'), anything)

      perform(tool.name)

      expect(posted_bodies.last['text']).not_to include('re-sent')
    end

    it 'rejects a tool with a revoked target checkout' do
      create(:tool_checkout, member: member, tool: tool, revoked_at: Time.current)

      expect {
        perform(tool.name)
      }.not_to change { ToolCheckoutRequest.count }
      expect(posted_bodies.last['text']).to include('checkout record already exists')
    end

    it 'resolves a shop configured with a Slack channel ID' do
      shop.update!(slack_channel: 'C12345678')

      expect {
        perform(tool.name, channel_name: 'woodshop', channel_id: 'C12345678')
      }.to change { ToolCheckoutRequest.count }.by(1)
    end

    it 'requires a non-revoked checkout for every prerequisite' do
      prerequisite = create(:tool, shop: shop)
      tool.update!(prerequisite_ids: [prerequisite.id.to_s])

      perform(tool.name)
      expect(posted_bodies.last['text']).to include('prerequisite')

      create(:tool_checkout, member: member, tool: prerequisite, revoked_at: Time.current)
      perform(tool.name)
      expect(posted_bodies.last['text']).to include('prerequisite')

      ToolCheckout.where(member_id: member.id, tool_id: prerequisite.id).delete_all
      create(:tool_checkout, member: member, tool: prerequisite)
      expect { perform(tool.name) }.to change(ToolCheckoutRequest, :count).by(1)
    end

    it 'allows pending members only on tools configured to allow them' do
      member.update!(status: 'pending')
      perform(tool.name)
      expect(posted_bodies.last['text']).to include('membership')

      tool.update!(allow_pending: true)
      expect { perform(tool.name) }.to change(ToolCheckoutRequest, :count).by(1)
    end

    it 'does not list disabled tools, tools in disabled shops, existing checkouts, or open requests' do
      existing_checkout = create(:tool, shop: shop, name: 'Has Checkout')
      open_request = create(:tool, shop: shop, name: 'Has Request')
      disabled = create(:tool, shop: shop, name: 'Disabled', disabled: true)
      create(:tool_checkout, member: member, tool: existing_checkout)
      ToolCheckoutRequest.create!(member: member, tool: open_request, status: 'open')
      perform(nil)

      text = posted_bodies.last['text']
      expect(text).not_to include(existing_checkout.name, open_request.name, disabled.name)
      shop.update!(disabled: true)
      perform(nil)
      expect(posted_bodies.last['text']).to include('No eligible tools')
    end

    it 'does not create a duplicate open request for the same tool' do
      ToolCheckoutRequest.create!(member: member, tool: tool, status: 'open')

      expect {
        perform(tool.name)
      }.not_to change { ToolCheckoutRequest.count }
      expect(posted_bodies.last['text']).to include('open request already exists')
    end

    it 'serializes concurrent request creation for the same member and tool' do
      allow(REDIS).to receive(:set)
        .with(
          "checkout_request_lock/#{member.id}/#{tool.id}",
          kind_of(String),
          nx: true,
          ex: 30
        )
        .and_return(false)

      expect {
        perform(tool.name)
      }.not_to change(ToolCheckoutRequest, :count)
      expect(posted_bodies.last['text']).to include('already being processed')
    end

    it 'does not create or announce a duplicate when another delivery runs while creation is locked' do
      allow(REDIS).to receive(:set).and_return(true, false)
      allow_any_instance_of(ToolCheckoutRequest).to receive(:announce_request) do
        perform(tool.name)
      end

      expect {
        perform(tool.name)
      }.to change(ToolCheckoutRequest, :count).by(1)

      expect(ToolCheckoutRequest.where(member_id: member.id, tool_id: tool.id, status: 'open').count).to eq(1)
      expect(posted_bodies.map { |body| body['text'] }).to include(
        a_string_including('already being processed'),
        a_string_including('Requested checkout')
      )
    end

    it 'rejects a Slack user with no linked Member account' do
      allow(::Service::SlackUserSync).to receive(:sync_single).and_return(nil)

      described_class.perform_now('response_url' => 'https://example.test/response', 'user_id' => 'UNLINKED', 'tool_name' => nil)

      expect(posted_bodies.last['text']).to include('Link your Slack account')
    end

    it 'rejects the command when run from a channel with no matching shop' do
      perform(tool.name, channel_name: 'not-a-shop-channel')

      expect(posted_bodies.last['text']).to include('No shop is configured')
    end

    it 'only matches tools in the shop the command was run from, even with a duplicate name in another shop' do
      other_shop = create(:shop, slack_channel: 'textile-arts')
      other_tool = create(:tool, shop: other_shop, name: tool.name)

      expect {
        perform(tool.name)
      }.to change { ToolCheckoutRequest.where(member_id: member.id, tool_id: tool.id, status: 'open').count }.by(1)

      expect(ToolCheckoutRequest.where(tool_id: other_tool.id).count).to eq(0)
    end

    it 'only lists eligible tools from the shop the command was run from' do
      other_shop = create(:shop, slack_channel: 'textile-arts')
      other_tool = create(:tool, shop: other_shop, name: 'Only In Other Shop')
      tool_name = tool.name

      perform(nil)

      expect(posted_bodies.last['text']).to include(tool_name)
      expect(posted_bodies.last['text']).not_to include(other_tool.name)
    end
  end
end
