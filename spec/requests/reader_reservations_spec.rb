require 'rails_helper'
RSpec.describe 'Private reader reservation synchronization', type: :request do
  around do |example|
    previous=ENV['READER_RESERVATION_SERVICE_SECRET']
    ENV['READER_RESERVATION_SERVICE_SECRET']='reader-service-test-secret-with-32-characters'
    example.run
  ensure
    ENV['READER_RESERVATION_SERVICE_SECRET']=previous
  end
  it 'rejects browser/no-token requests' do
    post '/api/internal/reader_reservations/sync',params:{operations:[]}.to_json,headers:{'CONTENT_TYPE'=>'application/json'}
    expect(response).to have_http_status(:unauthorized)
  end
  it 'passes verified service requests without browser session or CSRF' do
    allow(ReaderReservationService).to receive(:sync!).with({'deviceId'=>'device','operations'=>[]}).and_return(results:[],serverTime:123)
    post '/api/internal/reader_reservations/sync',params:{deviceId:'device',operations:[]}.to_json,
      headers:{'CONTENT_TYPE'=>'application/json','Authorization'=>"Bearer #{ENV['READER_RESERVATION_SERVICE_SECRET']}"}
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)).to include('results'=>[],'serverTime'=>123)
  end
end
