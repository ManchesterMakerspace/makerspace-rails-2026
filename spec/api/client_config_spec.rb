require 'swagger_helper'

describe 'Client configuration API', type: :request do
  before { allow(CloudflareRails::Importer).to receive(:cloudflare_ips).and_return([]) }

  path '/config' do
    get 'Gets public runtime client configuration' do
      tags 'Configuration'
      operationId 'getClientConfig'
      produces 'application/json'

      response '200', 'configuration found' do
        schema type: :object,
          properties: {
            firebase_api_key: { type: :string },
            firebase_project_id: { type: :string },
            firebase_auth_domain: { type: :string },
            firebase_auth_type: { type: :string },
            firebase_app_id: { type: :string },
            firebase_web_client_id: { type: :string },
            wiki_url: { type: :string },
            app_domain: { type: :string }
          },
          required: %i[firebase_api_key firebase_project_id firebase_auth_domain firebase_auth_type firebase_app_id firebase_web_client_id wiki_url app_domain]
        run_test!
      end
    end
  end
end
