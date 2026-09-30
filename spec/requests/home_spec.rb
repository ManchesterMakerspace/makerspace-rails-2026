require 'rails_helper'

RSpec.describe 'Member home', type: :request do
  before { allow(REDIS).to receive(:set).and_return(true) }

  it 'returns only the signed-in member, even for staff and when another ID is supplied' do
    member = create(:member, :admin, :current)
    other = create(:member, :current)
    sign_in member
    get '/api/home', params: { member_id: other.id.to_s }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('member', 'id')).to eq(member.id.to_s)
    expect(response.parsed_body.fetch('member')).not_to have_key('provisioning')
    expect(response.headers['Cache-Control']).to eq('private, no-store')
  end

  it 'does not expose data to anonymous sessions' do
    get '/api/home', as: :json
    expect(response).to have_http_status(:unauthorized)
    expect(response.headers['Cache-Control']).to eq('private, no-store')
  end

  [nil, 'T123'].each do |workspace_id|
    it "does not resolve Slack URLs while serializing Home with cached workspace #{workspace_id.inspect}" do
      member = create(:member, :current)
      SlackUser.create!(member: member, slack_id: 'U123', slack_email: member.email, real_name: 'Slack Member')
      member.reload.set(provisioning_email: member.email, slack_joined_at: Time.current, slack_acceptance_pending: false)
      sign_in member

      allow(Service::SlackConnector).to receive(:slack_team_id).and_return(workspace_id)
      allow(Service::SlackConnector).to receive(:new_members_channel).and_return('new_members')
      expect(Service::SlackConnector).not_to receive(:slack_user_url)
      expect(Service::SlackConnector).not_to receive(:init_team_id)
      expect(Service::SlackConnector).not_to receive(:client)

      get '/api/home', as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig('member', 'slack')).to include(
        'slackId' => 'U123', 'name' => 'Slack Member', 'url' => nil
      )
      expect(response.parsed_body.fetch('slack')).to eq(
        'accepted' => true,
        'newMembersChannelUrl' => workspace_id ? 'https://slack.com/app_redirect?team=T123&channel=new_members' : nil
      )
    end
  end

  it 'withholds Home until a password login completes its TOTP challenge' do
    member = create(:member, password: 'password123', otp_required_for_login: true, otp_secret_encrypted: 'test-secret')
    post '/api/members/sign_in', params: { member: { email: member.email, password: 'password123' } }, as: :json
    expect(response).to have_http_status(:accepted)
    get '/api/home', as: :json
    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body).not_to have_key('member')
  end

  it 'keeps Home invoice requests scoped to the member and excludes paid invoices' do
    member = create(:member, :admin, :current)
    sign_in member
    # Seed existing invoice states directly: the create-time duplicate-membership
    # validation and payment/email callbacks are unrelated to this read contract.
    invoices = [
      build(:invoice, member: member),
      build(:invoice, member: member, subscription_id: 'sub123'),
      build(:invoice, member: member, settled_at: Time.current),
      build(:invoice, member: member, transaction_id: 'paid123'),
      build(:invoice, member: create(:member))
    ]
    invoices.each { |invoice| Invoice.collection.insert_one(invoice.attributes) }
    get '/api/invoices', params: { settled: false, orderBy: 'due_date', order: 'asc' }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.pluck('id')).to contain_exactly(*invoices.first(2).map { |invoice| invoice.id.to_s })
  end
end
