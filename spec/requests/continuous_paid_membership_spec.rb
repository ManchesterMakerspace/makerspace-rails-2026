require 'rails_helper'

RSpec.describe 'Paid membership permissions and session protections', type: :request do
  let(:member) { create(:member) }
  let(:read_path) { "/api/members/#{member.id}/continuous_paid_membership" }
  let(:write_path) { "/api/admin/members/#{member.id}/continuous_paid_membership" }
  let(:body) { { continuousPaidMembershipMonths: 3, expectedRevision: 0, reason: 'Verified history' } }

  %w[admin board_member resource_manager member].each do |role|
    it "enforces #{role} read scope" do
      viewer = create(:member, role: role)
      sign_in viewer
      get read_path, as: :json
      expect(response).to have_http_status(%w[admin board_member].include?(role) ? :ok : :forbidden)
      get "/api/members/#{viewer.id}/continuous_paid_membership", as: :json
      expect(response).to have_http_status(:ok)
    end
  end

  %w[board_member resource_manager member].each do |role|
    it "rejects #{role} corrections even to their own account" do
      viewer = create(:member, role: role)
      sign_in viewer
      put "/api/admin/members/#{viewer.id}/continuous_paid_membership", params: body, as: :json
      expect(response).to have_http_status(:forbidden)
    end
  end

  [1.5, -1, 0, '3', nil].each do |value|
    it "rejects invalid/equal correction #{value.inspect}", requires_transactions: value == 0 do
      sign_in create(:member, :admin)
      put write_path, params: body.merge(continuousPaidMembershipMonths: value), as: :json
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  it 'rejects missing reasons and corrections after the exact expiration deadline', requires_transactions: true do
    sign_in create(:member, :admin)
    put write_path, params: body.merge(reason: '   '), as: :json
    expect(response).to have_http_status(:unprocessable_content)
    member.set(expirationTime: 240.hours.ago.to_i * 1000)
    put write_path, params: body, as: :json
    expect(response).to have_http_status(:unprocessable_content)
  end

  it 'keeps accounting fields out of generic self and Admin update parameters' do
    sign_in member
    put "/api/members/#{member.id}", params: { continuousPaidMembershipMonths: 999,
      continuousPaidMembershipBalance: '999', continuousPaidMembershipRevision: 123 }, as: :json
    expect(response).to have_http_status(:ok)
    sign_out member
    sign_in create(:member, :admin)
    put "/api/admin/members/#{member.id}", params: { continuousPaidMembershipMonths: 999,
      continuousPaidMembershipBalance: '999', continuousPaidMembershipRevision: 123 }, as: :json
    expect(response).to have_http_status(:ok)
    expect(member.reload.continuous_paid_membership_months).to eq(0)
    expect(member.continuous_paid_membership_revision).to eq(0)
  end

  it 'requires CSRF on the correction endpoint', requires_transactions: true do
    original = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    sign_in create(:member, :admin)
    put write_path, params: body, as: :json
    expect(response).to have_http_status(:unauthorized)
    get '/api/config', as: :json
    token = CGI.unescape(cookies['XSRF-TOKEN'])
    put write_path, params: body, headers: { 'X-XSRF-TOKEN' => token }, as: :json
    expect(response).to have_http_status(:ok)
  ensure
    ActionController::Base.allow_forgery_protection = original
  end

  it 'blocks both endpoints until the normal password TOTP challenge is completed' do
    admin = create(:member, :admin, password: 'password123', otp_required_for_login: true,
      otp_secret_encrypted: TotpService.encrypt(TotpService.generate_secret))
    post '/api/members/sign_in', params: { member: { email: admin.email, password: 'password123' } }, as: :json
    expect(response).to have_http_status(:accepted)
    get read_path, as: :json
    expect(response).to have_http_status(:unauthorized)
    put write_path, params: body, as: :json
    expect(response).to have_http_status(:unauthorized)
    expect(member.reload.continuous_paid_membership_months).to eq(0)
  end

  it 'treats a confirmed offline held receipt as paid without crediting duration early', requires_transactions: true do
    invoice = create(:invoice, member: member, resource_id: member.id.to_s, resource_class: 'member',
      amount: 120, quantity: 12, plan_id: nil, due_date: 1.day.ago)
    invoice.submit_for_settlement
    sign_in member
    get '/api/invoices', params: { settled: false }, as: :json
    expect(response.parsed_body.map { |row| row['id'] }).not_to include(invoice.id.to_s)
    get '/api/invoices', params: { settled: true }, as: :json
    expect(response.parsed_body.find { |row| row['id'] == invoice.id.to_s }['settled']).to be(true)
    expect(MembershipPaidCredit.read(member.id)[:continuousPaidMembershipMonths]).to eq(0)
    expect { invoice.reload.submit_for_settlement }.not_to change { Invoice.count }
    expect(invoice.reload.settled_at).to be_nil
    expect(MembershipPaidCredit.read(member.id)[:continuousPaidMembershipMonths]).to eq(0)
    expect(invoice.past_due).to be(false)
  end
end
