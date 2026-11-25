require "swagger_helper"

error_schema = {
  type: :object,
  properties: { error: { type: :string } },
  required: [:error]
}

RSpec.describe "Reservation agendas API", type: :request do
  path "/reservations/agenda" do
    get "Public 24-hour reservation agenda" do
      tags "Reservations"
      produces "application/json", "text/html"
      parameter name: :shop, in: :query, type: :string, required: true
      parameter name: :tool, in: :query, type: :string, required: false
      parameter name: :token, in: :query, type: :string, required: false

      response "200", "HTML or JSON agenda for the next 24 hours" do
        metadata[:response][:content] = {
          "application/json" => {
            schema: { "$ref" => "#/components/schemas/ReservationAgenda" }
          },
          "text/html" => { schema: { type: :string } }
        }

        it 'exposes independent shop and tool outage flags with effective availability' do |example|
          shop = create(:shop, out_of_service: true, out_of_service_note: 'Maintenance')
          get '/reservations/agenda.json', params: { shop: shop.name }
          assert_response_matches_metadata(example.metadata)
          expect(response.parsed_body).to include('outOfService' => true, 'shopOutOfService' => true, 'toolOutOfService' => false)
        end
      end

      response "400", "Shop parameter missing" do
        metadata[:response][:content] = {
          "application/json" => { schema: error_schema },
          "text/html" => { schema: { type: :string } }
        }

        it "returns a JSON error when the shop parameter is missing" do |example|
          get '/reservations/agenda.json'
          assert_response_matches_metadata(example.metadata)
          expect(response.parsed_body['error']).to include('required')
        end
      end

      response "403", "Configured token missing or invalid" do
        metadata[:response][:content] = {
          "application/json" => { schema: error_schema },
          "text/html" => { schema: { type: :string } }
        }

        it "refuses missing or invalid tokens when one is configured" do |example|
          shop = create(:shop)
          SystemConfig.set('reservation_token', 'secret')

          get '/reservations/agenda.json', params: { shop: shop.name }
          assert_response_matches_metadata(example.metadata)

          get '/reservations/agenda.json', params: { shop: shop.name, token: 'invalid' }
          assert_response_matches_metadata(example.metadata)
        end
      end

      response "404", "Shop or tool not found" do
        metadata[:response][:content] = {
          "application/json" => { schema: error_schema },
          "text/html" => { schema: { type: :string } }
        }

        it "returns HTML or JSON errors for unknown shops and tools" do |example|
          get '/reservations/agenda', params: { shop: 'Unknown' }
          assert_response_matches_metadata(example.metadata)
          expect(response.body).to eq('Shop was not found.')

          shop = create(:shop)
          get '/reservations/agenda.json', params: { shop: shop.name, tool: 'Unknown' }
          assert_response_matches_metadata(example.metadata)
          expect(response.parsed_body['error']).to include('Tool')
        end
      end
    end
  end
end
