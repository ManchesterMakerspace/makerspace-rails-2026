require 'rails_helper'
RSpec.describe FixSlack do
  let(:member) { create(:member, :current) }
  before do
    ActiveJob::Base.queue_adapter = :test
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
end
