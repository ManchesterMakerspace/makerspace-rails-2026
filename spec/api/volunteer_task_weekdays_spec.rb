require 'swagger_helper'

# The endpoint declarations and shared write/response schemas live in
# volunteer_task_responses_spec.rb; these exercise the weekday contract.
RSpec.describe 'Volunteer task weekday API contract', type: :request do
  let(:member) { create(:member, :current) }
  let(:admin) { create(:member, :admin, :current) }
  let(:shop) { create(:shop, name: 'Woodshop') }

  around do |example|
    travel_to(Time.utc(2026, 11, 20, 1)) { example.run }
  end

  before do
    ActiveJob::Base.queue_adapter = :test
    allow(Service::SlackConnector).to receive(:send_slack_message)
    allow(Service::SlackConnector).to receive(:enque_message)
    allow(SystemConfig).to receive(:get).and_call_original
    allow(SystemConfig).to receive(:get).with('volunteer_bounty_token_enabled').and_return('false')
  end

  def task(weekday: nil, status: 'repeatable', **attributes)
    VolunteerTask.create!({ title: "Task #{weekday.inspect}", description: 'Organize supplies',
      created_by_id: admin.id, shop_id: shop.id, status: status, day_of_week: weekday }.merge(attributes))
  end

  it 'creates, serializes, updates, and clears an optional weekday through the Rails API' do
    sign_in admin
    post '/api/admin/volunteer_tasks', params: { title: 'Sunday cleanup', description: 'Organize supplies',
      status: 'repeatable', dayOfWeek: 0, shopId: shop.id.to_s }, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include('dayOfWeek' => 0)
    id = response.parsed_body.fetch('id')

    put "/api/admin/volunteer_tasks/#{id}", params: { dayOfWeek: 4 }, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include('dayOfWeek' => 4)
    put "/api/admin/volunteer_tasks/#{id}", params: { dayOfWeek: nil }, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include('dayOfWeek' => nil)
    expect(VolunteerTask.find(id).day_of_week).to be_nil
  end

  [7, 2.5, 'Thursday'].each do |value|
    it "rejects invalid weekday #{value.inspect} without persisting a truncated value" do
      sign_in admin
      record = task(weekday: 4)
      put "/api/admin/volunteer_tasks/#{record.id}", params: { dayOfWeek: value }, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(record.reload.day_of_week).to eq(4)
    end
  end

  it 'filters member availability by Eastern weekday and exposes the schedule in the task response' do
    sign_in member
    matching = task(weekday: 4)
    other = task(weekday: 5)
    any_day = task
    get '/api/volunteer/tasks'
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(hash_including('id' => matching.id.to_s, 'dayOfWeek' => 4))
    expect(response.parsed_body.map { |row| row['id'] }).to contain_exactly(matching.id.to_s, any_day.id.to_s)
    expect(response.body).not_to include(other.id.to_s)
  end

  %w[member admin board_member resource_manager].each do |role|
    it "rejects a direct off-day API claim by #{role}" do
      actor = create(:member, :current, role: role)
      sign_in actor
      record = task(weekday: 5)
      post "/api/volunteer/tasks/#{record.id}/claim", params: {}, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(record.reload.status).to eq('repeatable')
      expect(VolunteerTask.where(parent_task_id: record.id)).to be_empty
    end
  end

  it 'keeps existing child claims visible and completable after the parent weekday passes' do
    sign_in member
    parent = task(weekday: 4)
    post "/api/volunteer/tasks/#{parent.id}/claim", params: {}, as: :json
    expect(response).to have_http_status(:ok)
    child_id = response.parsed_body.fetch('id')
    expect(response.parsed_body).to include('dayOfWeek' => nil)

    travel_to(Time.utc(2026, 11, 20, 17))
    sign_out member
    sign_in member
    get '/api/volunteer/tasks/my_claims'
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.map { |row| row['id'] }).to include(child_id)
    post "/api/volunteer/tasks/#{child_id}/complete", params: {}, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include('status' => 'pending')
  end

  %w[html json xml].each do |format|
    it "filters the public #{format} feed by weekday without hiding any-day tasks" do
      matching = task(weekday: 4, title: 'Thursday cleanup')
      task(weekday: 5, title: 'Friday cleanup')
      any_day = task(title: 'Any day cleanup')
      get "/volunteer/bounties.#{format}"
      expect(response).to have_http_status(:ok)
      if format == 'html'
        expect(response.body).to include('Volunteer Bounties', '/volunteer/bounties.json')
        # The display loads task rows from this JSON endpoint in the browser.
        get '/volunteer/bounties.json'
        expect(response).to have_http_status(:ok)
      end
      expect(response.body).to include(matching.title, any_day.title)
      expect(response.body).not_to include('Friday cleanup')
      if format == 'json'
        expect(response.parsed_body).to include(hash_including('id' => matching.id.to_s, 'day_of_week' => 4))
      end
    end
  end
end
