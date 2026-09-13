require 'rails_helper'

RSpec.describe Admin::AnalyticsController, type: :controller do
  set_devise_mapping

  before do
    sign_in create(:member, :admin)
    allow(Service::Analytics::Members).to receive(:summary_counts).and_return(
      total_members: 10, new_members: 2, lost_members: 1, subscribed_members: 7
    )
    allow(Service::Analytics::Invoices).to receive(:summary_counts).and_return(
      past_due_invoices: 1, refunds_pending: 3
    )
    allow(Service::CardExpirationCheck).to receive(:expiring_member_count).and_return(4)
  end

  it 'includes the cached count of members with expiring payment methods' do
    get :index, format: :json

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)['membersWithExpiringPaymentMethods']).to eq(4)
  end

  it 'includes the count of lost members' do
    get :index, format: :json

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)['lostMembers']).to eq(1)
  end

  it 'uses the shared aggregation for lost members by month' do
    rows = [{ month: '2024-01', count: 2 }, { month: '2024-02', count: 0 }]
    expect(Service::Analytics::Members).to receive(:lost_members_by_month).with(
      start_date: Date.new(2024, 1, 1),
      end_date: Date.new(2024, 12, 31)
    ).and_return(rows)

    get :member_losses, params: { year: 2024 }, format: :json

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body, symbolize_names: true)).to eq(rows)
  end

  it 'uses the shared aggregation for active members' do
    rows = [{ date: '2024-01', count: 3 }, { date: '2024-02', count: 0 }]
    expect(Service::Analytics::Members).to receive(:active_members_by_month).with(
      start_date: Date.new(2024, 1, 1),
      end_date: Date.new(2024, 12, 31),
      statuses: Member::ACTIVE_MEMBERSHIP_STATUSES
    ).and_return(rows)

    get :active_members, params: { year: 2024 }, format: :json

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body, symbolize_names: true)).to eq(rows)
  end
end
