require 'rails_helper'

RSpec.describe 'Volunteer form validation', type: :request do
  let(:admin) { create(:member, :admin, :current) }

  before do
    sign_in admin
    allow(VolunteerTask).to receive(:max_credit_value).and_return(1.5)
    allow(Service::SlackConnector).to receive(:enque_message)
    allow(Service::SlackConnector).to receive(:send_slack_message)
  end

  def expect_credit_error
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body).to include('status' => 422, 'error' => 'unprocessable_content')
    expect(response.parsed_body['message']).to include('Credit value')
    expect(response.parsed_body.dig('errors', 'credit_value')).to be_present
    expect(response.parsed_body['message']).not_to include('Mongoid', 'Problem:', 'Resolution:')
  end

  it 'explains the current creation cap and leaves an oversized new task unsaved' do
    expect do
      post '/api/admin/volunteer_tasks', params: {
        title: 'Clean the shop', description: 'Put tools away', credit_value: 2
      }, as: :json
    end.not_to change(VolunteerTask, :count)
    expect_credit_error
    expect(response.parsed_body['message']).to include('cannot exceed 1.5 credits')
  end

  it 'keeps existing task edits uncapped and returns friendly errors for invalid values' do
    task = VolunteerTask.create!(title: 'Clean the shop', description: 'Put tools away', credit_value: 1)
    put "/api/admin/volunteer_tasks/#{task.id}", params: { credit_value: 1000 }, as: :json
    expect(response).to have_http_status(:ok)
    expect(task.reload.credit_value).to eq(1000)
    put "/api/admin/volunteer_tasks/#{task.id}", params: { credit_value: 0 }, as: :json
    expect_credit_error
    expect(task.reload.credit_value).to eq(1000)
  end

  it 'keeps events uncapped on creation and edits, while explaining invalid values' do
    post '/api/admin/volunteer_events', params: { title: 'Open house', credit_value: 1000 }, as: :json
    expect(response).to have_http_status(:ok)
    event = VolunteerEvent.find(response.parsed_body['id'])
    expect(event.credit_value).to eq(1000)
    put "/api/admin/volunteer_events/#{event.id}", params: { credit_value: 2000 }, as: :json
    expect(response).to have_http_status(:ok)
    post '/api/admin/volunteer_events', params: { title: 'Invalid event', credit_value: 0 }, as: :json
    expect_credit_error
    put "/api/admin/volunteer_events/#{event.id}", params: { credit_value: 0 }, as: :json
    expect_credit_error
    expect(event.reload.credit_value).to eq(2000)
  end
end
