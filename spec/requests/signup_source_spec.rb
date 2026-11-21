require 'rails_helper'
RSpec.describe 'Provider signup source', type: :request do
  before { allow(Service::MemberProvisioning).to receive(:invite_slack) }
  it 'saves only the current member, permits skipping and does not repeat the prompt' do
    member = create(:member, signup_source_prompt_pending: true)
    other = create(:member, signup_source_prompt_pending: true)
    sign_in member
    put '/api/signup_source', params: { id: other.id.to_s, signupSource: '' }, as: :json
    expect(response).to have_http_status(:ok)
    expect(member.reload.signup_source_prompt_pending).to be(false)
    expect(member.signup_source_asked_at).to be_present
    expect(other.reload.signup_source_prompt_pending).to be(true)
    put '/api/signup_source', params: { signupSource: 'other', signupSourceDetail: 'Overwrite' }, as: :json
    expect(member.reload.signup_source).to be_nil
  end
  it 'keeps the prompt pending when an event becomes unavailable' do
    member = create(:member, signup_source_prompt_pending: true)
    sign_in member
    put '/api/signup_source', params: { signupSource: 'eventbrite', signupEventbriteEventId: BSON::ObjectId.new.to_s }, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(member.reload.signup_source_prompt_pending).to be(true)
    put '/api/signup_source', params: { signupSource: 'declined' }, as: :json
    expect(response).to have_http_status(:ok)
    expect(member.reload.signup_source).to eq('declined')
  end
  it 'retains existing source choices and enforces the detail limit' do
    Member::SIGNUP_SOURCES.reject { |s| s == 'eventbrite' }.each do |source|
      member = build(:member, signup_source: source, signup_source_detail: 'Explanation')
      expect(member).to be_valid
    end
    expect(build(:member, signup_source: 'other', signup_source_detail: 'x' * 101)).not_to be_valid
  end

  it 'returns the same public event choices from the display cache' do
    event = EventbriteEvent.create!(organization_id: 'org', eventbrite_id: 'public', name: 'Workshop',
      starts_at: Time.current, timezone: 'America/New_York', status: 'live', listed: true)
    allow(EventbriteIntegration::Configuration).to receive(:organization_ids).and_return(['org'])
    get '/api/signup_events'
    expect(response).to have_http_status(:ok)
    original = JSON.parse(response.body)
    expect(original).to eq([{ 'id' => event.id.to_s, 'name' => 'Workshop',
      'startsAt' => event.starts_at.iso8601, 'timezone' => 'America/New_York' }])
    expect(EventbriteEvent).not_to receive(:signup_choices)
    get '/api/signup_events'
    expect(JSON.parse(response.body)).to eq(original)
  end

  it 'validates signup eligibility from MongoDB even when display invalidation is unavailable' do
    allow(EventbriteIntegration::Configuration).to receive(:organization_ids).and_return(['org'])
    event = EventbriteEvent.create!(organization_id: 'org', eventbrite_id: 'stale', name: 'Workshop',
      starts_at: Time.current, timezone: 'America/New_York', status: 'live', listed: true)
    member = create(:member, signup_source_prompt_pending: true)
    get '/api/signup_events'
    expect(JSON.parse(response.body).map { |row| row['id'] }).to include(event.id.to_s)
    allow(EventbriteIntegration::DisplayCache).to receive(:invalidate_signup_choices)
    event.update!(listed: false)
    get '/api/signup_events'
    expect(JSON.parse(response.body).map { |row| row['id'] }).to include(event.id.to_s)
    sign_in member
    put '/api/signup_source', params: { signupSource: 'eventbrite', signupEventbriteEventId: event.id.to_s }, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(member.reload.signup_source_prompt_pending).to be(true)
  end
end
