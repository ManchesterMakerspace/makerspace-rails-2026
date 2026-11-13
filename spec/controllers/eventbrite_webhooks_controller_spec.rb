require 'rails_helper'
RSpec.describe EventbriteWebhooksController, type: :controller do
  before do
    @routes = ActionDispatch::Routing::RouteSet.new
    @routes.draw { post 'receiver' => 'eventbrite_webhooks#create' }
    request.headers['CONTENT_TYPE'] = 'application/json'
    allow(EventbriteDeliveryJob).to receive(:perform_later)
  end
  def deliver(body)
    post :create, body: body.to_json
  end
  EventbriteIntegration::Resource::ACTIONS.each do |type, actions|
    actions.each do |action|
      it "accepts #{action}" do
        path = { 'event' => 'events/e/', 'order' => 'orders/o/', 'attendee' => 'events/e/attendees/a/', 'ticket_class' => 'events/e/ticket_classes/t/' }.fetch(type)
        deliver('api_url' => "https://www.eventbriteapi.com/v3/#{path}", 'config' => { 'action' => action })
        expect(response).to have_http_status(:accepted)
        expect(EventbriteWebhookDelivery.last.action).to eq(action)
      end
    end
  end
  it 'acknowledges unsupported actions without processing and rejects malformed JSON' do
    deliver('api_url' => 'https://www.eventbriteapi.com/v3/orders/1/', 'config' => { 'action' => 'order.unrecognized' })
    expect(response).to have_http_status(:no_content)
    expect(EventbriteWebhookDelivery.count).to eq(0)
    post :create, body: '{'
    expect(response).to have_http_status(:bad_request)
  end
  it 'persists identical pointer notifications separately and acknowledges after persistence' do
    2.times { deliver('api_url' => 'https://www.eventbriteapi.com/v3/orders/1/') }
    expect(response).to have_http_status(:accepted)
    expect(EventbriteWebhookDelivery.count).to eq(2)
  end
  it 'retains delivery when enqueue fails' do
    allow(EventbriteDeliveryJob).to receive(:perform_later).and_raise('queue unavailable')
    deliver('api_url' => 'https://www.eventbriteapi.com/v3/orders/1/')
    expect(response).to have_http_status(:accepted)
    expect(EventbriteWebhookDelivery.count).to eq(1)
  end
  it 'rejects mismatched actions and handles dashboard tests without fetching' do
    deliver('api_url' => 'https://www.eventbriteapi.com/v3/orders/1/', 'config' => { 'action' => 'event.published' })
    expect(response).to have_http_status(:bad_request)
    deliver('config' => { 'action' => 'test' }, 'api_url' => 'placeholder')
    expect(response).to have_http_status(:ok)
    expect(EventbriteWebhookDelivery.count).to eq(0)
  end
  it 'returns service unavailable if persistence fails' do
    allow(EventbriteWebhookDelivery).to receive(:create!).and_raise(Mongo::Error, 'unavailable')
    deliver('api_url' => 'https://www.eventbriteapi.com/v3/orders/1/')
    expect(response).to have_http_status(:service_unavailable)
  end
end
