require 'rails_helper'

RSpec.describe 'Client runtime configuration', type: :request do
  describe 'GET /api/config' do
    before do
      allow(ENV).to receive(:[]).and_call_original
    end

    it 'exposes the effective task creation credit limit as a public number' do
      allow(VolunteerTask).to receive(:max_credit_value).and_return(1.5)
      get '/api/config', as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['volunteer_task_max_credit']).to eq(1.5)
    end

    it 'includes the Turnstile site key when configured' do
      allow(ENV).to receive(:[]).with('TURNSTILE_SITE_KEY').and_return('  public-site-key  ')

      get '/api/config', as: :json

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['turnstile_site_key']).to eq('public-site-key')
    end

    it 'omits the Turnstile site key when the environment variable is absent' do
      allow(ENV).to receive(:[]).with('TURNSTILE_SITE_KEY').and_return(nil)

      get '/api/config', as: :json

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).not_to have_key('turnstile_site_key')
    end

    it 'omits the Turnstile site key when the environment variable is blank' do
      allow(ENV).to receive(:[]).with('TURNSTILE_SITE_KEY').and_return('  ')

      get '/api/config', as: :json

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).not_to have_key('turnstile_site_key')
    end
  end
end
