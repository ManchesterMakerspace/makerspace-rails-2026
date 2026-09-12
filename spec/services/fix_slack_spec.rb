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
  it 'clears a shop through the edit modal No shop choice' do
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
