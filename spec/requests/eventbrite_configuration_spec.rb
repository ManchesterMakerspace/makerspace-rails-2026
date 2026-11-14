require 'rails_helper'

RSpec.describe 'Eventbrite webhook configuration', type: :request do
  let(:private_path) { "/eventbrite/#{'a' * 32}" }

  around do |example|
    keys = %w[EVENTBRITE_WEBHOOK_PATH EVENTBRITE_API_KEY EVENTBRITE_ORGANIZATION_IDS]
    old = keys.to_h { |key| [key, ENV[key]] }
    ENV['EVENTBRITE_API_KEY'] = 'test-only'
    ENV['EVENTBRITE_ORGANIZATION_IDS'] = 'org-1'
    example.run
  ensure
    old.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
    Rails.application.reload_routes!
  end

  def receiver_routes
    Rails.application.routes.routes.select { |route| route.defaults[:controller] == 'eventbrite_webhooks' }
  end

  ["/short-secret", "eventbrite/#{'a' * 32}", "/eventbrite/#{'a' * 32}/",
   "https://example.invalid/#{'a' * 32}", "/eventbrite/#{'a' * 32}?query=1",
   *%w[api assets billing slack members rails].map { |prefix| "/#{prefix}/#{'a' * 32}" }].each do |path|
    it "disables the receiver without preventing route loading for #{path}" do
      ENV['EVENTBRITE_WEBHOOK_PATH'] = path
      ENV.delete('EVENTBRITE_API_KEY')
      ENV.delete('EVENTBRITE_ORGANIZATION_IDS')
      expect(Rails.logger).to receive(:warn) do |message|
        expect(message).to include('Eventbrite webhook disabled', 'EVENTBRITE_WEBHOOK_PATH')
        expect(message).not_to include(path)
      end

      expect { Rails.application.reload_routes! }.not_to raise_error
      expect(receiver_routes).to be_empty
    end
  end

  it 'silently disables the receiver for a blank setting' do
    ENV['EVENTBRITE_WEBHOOK_PATH'] = ' '
    expect(Rails.logger).not_to receive(:warn)
    Rails.application.reload_routes!
    expect(receiver_routes).to be_empty
  end

  it 'continues serving ordinary routes when the invalid path conflicts with one' do
    ENV['EVENTBRITE_WEBHOOK_PATH'] = '/api/config'
    allow(Rails.logger).to receive(:warn)
    Rails.application.reload_routes!
    get '/api/config'
    expect(response).to have_http_status(:ok)
    expect(request.env['eventbrite.private_receiver']).to be_nil
  end

  it 'accepts dashboard tests on a valid private path and redacts the path' do
    ENV['EVENTBRITE_WEBHOOK_PATH'] = private_path
    Rails.application.reload_routes!
    expect(receiver_routes.size).to eq(1)
    post private_path, params: { config: { action: 'test' } }, as: :json
    expect(response).to have_http_status(:ok)
    expect(request.env['PATH_INFO']).to eq('/__eventbrite_receiver__')
  end

  it 'still requires API credentials when enabling a valid path' do
    ENV['EVENTBRITE_WEBHOOK_PATH'] = private_path
    ENV.delete('EVENTBRITE_API_KEY')
    expect { EventbriteIntegration::Configuration.validate_path! }.to raise_error(
      ArgumentError, 'Eventbrite API token and organization IDs are required'
    )
  end
end
