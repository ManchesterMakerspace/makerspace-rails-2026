require 'swagger_helper'

RSpec.describe 'Public runtime configuration', type: :request do
  path '/config' do
    get 'Gets safe runtime configuration before login' do
      tags 'Configuration'
      operationId 'getClientConfig'
      produces 'application/json'
      security []
      response '200', 'Public integration settings and the ordinary task creation credit maximum' do
        schema type: :object, required: %w[firebase_api_key firebase_project_id firebase_auth_domain firebase_auth_type wiki_url app_domain volunteer_task_max_credit],
          properties: {
            firebase_api_key: { type: :string }, firebase_project_id: { type: :string },
            firebase_auth_domain: { type: :string }, firebase_auth_type: { type: :string },
            wiki_url: { type: :string }, app_domain: { type: :string }, turnstile_site_key: { type: :string },
            volunteer_task_max_credit: { type: :number, description: 'Effective maximum when creating an ordinary volunteer task; existing task edits and volunteer events remain uncapped.' }
          }
        before { allow(VolunteerTask).to receive(:max_credit_value).and_return(1.5) }
        run_test! { |response| expect(response.parsed_body['volunteer_task_max_credit']).to eq(1.5) }
      end
    end
  end
end
