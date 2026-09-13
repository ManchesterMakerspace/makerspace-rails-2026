require 'rails_helper'
RSpec.describe FixSlack do
  let(:member) { create(:member, :current) }
  before do
    ActiveJob::Base.queue_adapter = :test
    allow(ShortUrl).to receive(:base_url).and_return('https://portal.example.com')
    allow(REDIS).to receive(:set).and_return(true)
    allow(REDIS).to receive(:eval).and_return(1)
  end
  it 'uses searchable tool selections and a private submission key' do
    view = described_class.command_view(member, 'new')
    tool = view[:blocks].find { |block| block[:block_id] == 'tool_id' }
    expect(tool[:element][:type]).to eq('external_select')
    expect(JSON.parse(view[:private_metadata])['submission_key']).to be_present
  end
  it 'renders each scoped paginated list and complete filter controls' do
    %w[mine assigned queue public].each do |mode|
      view = described_class.command_view(member, mode)
      expect(JSON.parse(view[:private_metadata])['page_size']).to eq(10)
    end
    filter_ids = described_class.filters({})[:blocks].map { |block| block[:block_id] }
    expect(filter_ids).to include('shop_id', 'priority', 'statuses', 'category', 'confirmation', 'tool_id', 'assignee_id')
  end
  it 'rejects a workspace mismatch before resolving identity' do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('SLACK_TEAM_ID').and_return('T_EXPECTED')
    expect { described_class.member!({ 'team_id' => 'T_OTHER', 'user_id' => 'U_OTHER' }) }.to raise_error(Error::Forbidden)
  end
  it 'limits assignee filter suggestions to visible ticket participants, including expired assignees' do
    visible = create(:member, :current, firstname: 'Visible')
    expired = create(:member, :expired, firstname: 'Former')
    outsider = create(:member, :current, firstname: 'Unrelated')
    create(:fix_ticket, reporter_id: member.id, assignee_ids: [visible.id, expired.id])
    create(:fix_ticket, reporter_id: outsider.id, assignee_ids: [outsider.id])
    payload = { 'action_id' => 'fix_search_assignee_id', 'value' => '' }
    expect(described_class.options(member, payload)[:options].map { |o| o[:value] }).to contain_exactly(visible.id.to_s, expired.id.to_s)
    expect(described_class.options(member, payload.merge('value' => 'Unrelated'))[:options]).to be_empty
    expect(described_class.options(member, payload.merge('value' => 'Vis'))[:options].map { |o| o[:value] }).to eq([visible.id.to_s])
  end
  it 'initializes tool and assignee filters without losing their IDs' do
    tool = create(:tool, shop: create(:shop))
    query = { 'tool_id' => tool.id.to_s, 'assignee_id' => member.id.to_s }
    view = described_class.filters(query)
    %w[tool_id assignee_id].each do |key|
      element = view[:blocks].find { |block| block[:block_id] == key }[:element]
      expect(element[:initial_option][:value]).to eq(query[key])
    end
    expect(JSON.parse(view[:private_metadata])).to include(query)
  end
  it 'clears a shop through the edit modal No shop choice', requires_transactions: true do
    admin = create(:member, :admin, :current)
    ticket = FixTicketService.create!(actor: member, attributes: { title: 'Repair', description: 'Broken', category: 'broken', shop_id: create(:shop).id.to_s, submission_key: SecureRandom.uuid })
    allow(described_class).to receive(:member!).and_return(admin)
    result = described_class.interaction({ 'type' => 'view_submission', 'view' => {
      'callback_id' => 'fix_edit', 'private_metadata' => { id: ticket.id.to_s }.to_json,
      'state' => { 'values' => { 'shop_id' => { 'fix_search_shop_id' => { 'selected_option' => { 'value' => 'none' } } } } }
    } })
    expect(result[:response_action]).to eq('update')
    expect(ticket.reload.shop_id).to be_nil
  end

end
