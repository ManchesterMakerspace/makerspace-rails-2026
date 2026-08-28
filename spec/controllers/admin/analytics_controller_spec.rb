require 'rails_helper'

RSpec.describe Admin::AnalyticsController, type: :controller do
  set_devise_mapping

  before do
    sign_in create(:member, :admin)
    allow(Service::Analytics::Members).to receive(:query_total_members).and_return(double(count: 10))
    allow(Service::Analytics::Members).to receive(:query_new_members).and_return(double(count: 2))
    allow(Service::Analytics::Members).to receive(:query_braintree_members).and_return(double(count: 7))
    allow(Service::Analytics::Invoices).to receive(:query_past_due).and_return(double(count: 1))
    allow(Service::Analytics::Invoices).to receive(:query_refunds_pending).and_return(double(count: 3))
    allow(Service::CardExpirationCheck).to receive(:expiring_member_count).and_return(4)
  end

  it 'includes the cached count of members with expiring payment methods' do
    get :index, format: :json

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)['membersWithExpiringPaymentMethods']).to eq(4)
  end

  it 'uses the shared aggregation for active members' do
    rows = [{ date: '2024-01', count: 3 }, { date: '2024-02', count: 0 }]
    expect(Service::Analytics::Members).to receive(:active_members_by_month).with(
      start_date: Date.new(2024, 1, 1),
      end_date: Date.new(2024, 12, 31)
    ).and_return(rows)

    get :active_members, params: { year: 2024 }, format: :json

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body, symbolize_names: true)).to eq(rows)
  end
end
