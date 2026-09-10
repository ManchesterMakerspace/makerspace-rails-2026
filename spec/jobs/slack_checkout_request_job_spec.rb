require 'rails_helper'

RSpec.describe SlackCheckoutRequestJob do
  let(:shop) { create(:shop) }
  let(:member) { create(:member, :current) }
  let(:tool) { create(:tool, shop: shop, notes: 'Combo: 4-5-6') }
  let!(:slack_user) { SlackUser.create!(member: member, slack_id: 'U123', slack_email: member.email) }
  let(:posted_bodies) { [] }

  before do
    allow(::Service::SlackConnector).to receive(:send_slack_message)

    http = instance_double(Net::HTTP)
    allow(Net::HTTP).to receive(:new).and_return(http)
    allow(http).to receive(:use_ssl=)
    allow(http).to receive(:request) do |req|
      posted_bodies << JSON.parse(req.body)
    end
  end

  def perform(tool_name)
    described_class.perform_now('response_url' => 'https://example.test/response', 'user_id' => 'U123', 'tool_name' => tool_name)
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

  it 'resends the notes DM instead of creating a request when already checked out' do
    create(:tool_checkout, member: member, tool: tool)

    expect {
      perform(tool.name)
    }.not_to change { ToolCheckoutRequest.count }
    expect(::Service::SlackConnector).to have_received(:send_slack_message).with(a_string_including('Combo: 4-5-6'), 'U123')
  end

  it 'does not create a duplicate open request for the same tool' do
    ToolCheckoutRequest.create!(member: member, tool: tool, status: 'open')

    expect {
      perform(tool.name)
    }.not_to change { ToolCheckoutRequest.count }
    expect(posted_bodies.last['text']).to include('already have an open request')
  end

  it 'rejects a Slack user with no linked Member account' do
    allow(::Service::SlackUserSync).to receive(:sync_single).and_return(nil)

    described_class.perform_now('response_url' => 'https://example.test/response', 'user_id' => 'UNLINKED', 'tool_name' => nil)

    expect(posted_bodies.last['text']).to include('Link your Slack account')
  end
end
