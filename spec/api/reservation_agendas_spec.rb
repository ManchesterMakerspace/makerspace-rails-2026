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

        it("documents the response") { }
      end

      response "400", "Shop parameter missing" do
        metadata[:response][:content] = {
          "application/json" => { schema: error_schema },
          "text/html" => { schema: { type: :string } }
        }

        it("documents the response") { }
      end

      response "403", "Configured token missing or invalid" do
        metadata[:response][:content] = {
          "application/json" => { schema: error_schema },
          "text/html" => { schema: { type: :string } }
        }

        it("documents the response") { }
      end

      response "404", "Shop or tool not found" do
        metadata[:response][:content] = {
          "application/json" => { schema: error_schema },
          "text/html" => { schema: { type: :string } }
        }

        it("documents the response") { }
      end
    end
  end
end
