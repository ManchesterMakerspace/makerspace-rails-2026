require 'rails_helper'
RSpec.describe 'Fix ticket API', type: :request do
  let(:member) { create(:member, :current) }
  let(:admin) { create(:member, :current, :admin) }
  before do
    ActiveJob::Base.queue_adapter = :test
    allow(REDIS).to receive(:set).and_return(true)
    allow(REDIS).to receive(:eval).and_return(1)
    sign_in member
  end
  def submit(extra = {})
    post '/api/fix_tickets', params: { title: 'Drill', description: 'Broken switch', category: 'broken', submission_key: SecureRandom.uuid }.merge(extra), as: :json
    expect(response).to have_http_status(:ok)
    JSON.parse(response.body)
  end
  it 'creates a report and paginates without exposing reporter identities' do
    first = submit(priority: 1)
    submit(priority: 2)
    get '/api/fix_tickets', params: { mode: 'mine', page_size: 1 }
    expect(response).to have_http_status(:ok)
    data = JSON.parse(response.body)
    expect(data['total']).to eq(2)
    expect(data['tickets'].length).to eq(1)
    expect(response.body).not_to include(member.id.to_s, member.email)
    get "/api/fix_tickets/#{first['id']}"
    expect(JSON.parse(response.body)['events'].first['actor']).to eq('Reporter')
  end
  it 'requires an admin privacy acknowledgment for identity reveal' do
    ticket = submit
    post "/api/fix_tickets/#{ticket['id']}/reveal", params: { acknowledged: true }, as: :json
    expect(response).to have_http_status(:forbidden)
    sign_in admin
    post "/api/fix_tickets/#{ticket['id']}/reveal", params: {}, as: :json
    expect(response).to have_http_status(:forbidden)
    post "/api/fix_tickets/#{ticket['id']}/reveal", params: { acknowledged: true }, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.headers['Cache-Control']).to include('no-store')
    expect(JSON.parse(response.body)['id']).to eq(member.id.to_s)
    expect(FixTicketReveal.count).to eq(1)
  end
  it 'denies a read-only viewer mutations and excludes nonmatching statuses' do
    ticket = submit(public_read_only: true)
    viewer = create(:member, :current)
    sign_in viewer
    get "/api/fix_tickets/#{ticket['id']}"
    expect(response).to have_http_status(:ok)
    post "/api/fix_tickets/#{ticket['id']}/notes", params: { note: 'Not authorized' }, as: :json
    expect(response).to have_http_status(:forbidden)
    get '/api/fix_tickets', params: { mode: 'public', statuses: ['resolved', 'rejected'] }
    expect(JSON.parse(response.body)['total']).to eq(0)
  end
  it 'explains creation eligibility when capped or expired' do
    SystemConfig.set('ticket_open_limit', '1')
    submit
    get '/api/fix_tickets/catalog'
    body = JSON.parse(response.body)
    expect(body['canCreate']).to be(false)
    expect(body['creationUnavailableReason']).to include('limit')
    member.set(expirationTime: 1.day.ago.to_i * 1000)
    get '/api/fix_tickets/catalog'
    expect(JSON.parse(response.body)['creationUnavailableReason']).to include('active, unexpired')
  end
  it 'returns bounty capabilities for the viewer rather than the global task status' do
    task = VolunteerTask.create!(title: 'Repair', description: 'Replace switch', credit_value: 1, created_by_id: admin.id)
    get "/api/volunteer/tasks/#{task.id}/detail"
    expect(JSON.parse(response.body)['capabilities']).to eq('canClaim' => true, 'canSubmitCompletion' => false)
    task.set(status: 'claimed', claimed_by_id: admin.id)
    get "/api/volunteer/tasks/#{task.id}/detail"
    expect(JSON.parse(response.body)['capabilities']).to eq('canClaim' => false, 'canSubmitCompletion' => false)
    sign_in admin
    get "/api/volunteer/tasks/#{task.id}/detail"
    expect(JSON.parse(response.body)['capabilities']['canSubmitCompletion']).to be(true)
  end

end
