require "swagger_helper"

describe "Slack interactions API", type: :request do
  path "/slack/interactions" do
    post "Handles signed Slack modal interactions",
      operation: { servers: [{ url: "/", description: "Application root" }] } do
      tags "SlackInteractions"
      operationId "slackInteractions"
      consumes "application/x-www-form-urlencoded"
      produces "application/json"
      parameter name: :"X-Slack-Signature", in: :header, type: :string,
        required: true, description: "Slack v0 request signature"
      parameter name: :"X-Slack-Request-Timestamp", in: :header, type: :string,
        required: true, description: "Unix timestamp covered by the Slack signature"
      parameter name: :interaction, in: :body, schema: {
        type: :object,
        properties: {
          payload: {
            type: :string,
            pattern: '"type":"(view_submission|block_actions|view_closed)"',
            description: "JSON-encoded Slack interaction. Reservation views accept view_submission, " \
              "view_closed, and block_actions; block actions include actions and current view state.",
            example: {
              type: "block_actions",
              user: { id: "U12345678" },
              actions: [{ action_id: "reservation_tools_changed", selected_options: [] }],
              view: {
                id: "V12345678",
                hash: "view-hash",
                callback_id: "reservation_submit",
                private_metadata: "{}",
                state: { values: {} }
              }
            }.to_json
          }
        },
        required: ["payload"]
      }

      response "200", "interaction acknowledged or modal response returned" do
        let(:"X-Slack-Signature") { "v0=documented-by-signature-header" }
        let(:"X-Slack-Request-Timestamp") { Time.current.to_i.to_s }
        let(:interaction) do
          { payload: { type: "view_closed", view: { callback_id: "unrelated_view" } }.to_json }
        end

        before do
          allow_any_instance_of(Slack::InteractionsController)
            .to receive(:verify_slack_signature)
        end

        schema type: :object,
          description: "Empty acknowledgement, modal clear action, or field validation errors",
          additionalProperties: true

        it "documents and acknowledges view closure payloads" do
          post "/slack/interactions", params: interaction, headers: {
            "X-Slack-Signature" => public_send(:"X-Slack-Signature"),
            "X-Slack-Request-Timestamp" => public_send(:"X-Slack-Request-Timestamp")
          }

          expect(response).to have_http_status(:ok)
          expect(response.parsed_body).to eq({})
        end
      end

      response "403", "Slack signature is missing, invalid, or stale" do
        schema type: :object,
          properties: { error: { type: :string } },
          required: ["error"]

        let(:interaction) { { payload: {}.to_json } }
        let(:"X-Slack-Signature") { "v0=stale" }
        let(:"X-Slack-Request-Timestamp") { 10.minutes.ago.to_i.to_s }

        before do
          allow(ENV).to receive(:[]).and_call_original
          allow(ENV).to receive(:[]).with("SLACK_SIGNING_SECRET").and_return("documented-secret")
        end

        it "rejects a stale interaction" do
          post "/slack/interactions", params: interaction, headers: {
            "X-Slack-Signature" => public_send(:"X-Slack-Signature"),
            "X-Slack-Request-Timestamp" => public_send(:"X-Slack-Request-Timestamp")
          }

          expect(response).to have_http_status(:forbidden)
          expect(response.parsed_body).to eq("error" => "Request too old")
        end
      end
    end
  end
end
