require "swagger_helper"

describe "Slack commands API", type: :request do
  path "/slack/commands/checkout" do
    post "Handles the Slack checkout slash command",
      operation: { servers: [{ url: "/", description: "Application root" }] } do
      tags "SlackCommands"
      operationId "slackCheckoutCommand"
      consumes "application/x-www-form-urlencoded"
      produces "application/json"
      parameter name: :"X-Slack-Signature", in: :header, type: :string,
        required: true, description: "Slack v0 request signature"
      parameter name: :"X-Slack-Request-Timestamp", in: :header, type: :string,
        required: true, description: "Unix timestamp covered by the Slack signature"
      parameter name: :command_details, in: :body, schema: {
        type: :object,
        properties: {
          command: { type: :string, example: "/checkout" },
          text: {
            type: :string,
            description: "Empty text opens the stateful checkout menu (my checkouts, request a checkout, open requests). Shop channels lock the shop; elsewhere the modal offers enabled shops. Linked pending members may enter; expired, revoked, suspended and inactive members receive specific ephemeral errors. Legacy text: MEMBER TOOL, request [TOOL], or active [all]."
          },
          trigger_id: { type: :string, description: "Required to open the checkout modal" },
          channel_id: { type: :string },
          channel_name: { type: :string },
          user_id: { type: :string },
          user_name: { type: :string },
          response_url: { type: :string, format: :uri }
        },
        required: %w[text channel_id channel_name user_id response_url]
      }

      response "200", "command accepted with an ephemeral acknowledgement" do
        let(:"X-Slack-Signature") { "v0=documented-by-signature-header" }
        let(:"X-Slack-Request-Timestamp") { Time.current.to_i.to_s }
        let(:command_details) do
          {
            command: "/checkout",
            text: "active",
            channel_id: "C12345678",
            channel_name: "woodshop",
            user_id: "U12345678",
            user_name: "member",
            response_url: "https://hooks.slack.com/commands/response"
          }
        end

        before do
          allow_any_instance_of(Slack::CommandsController)
            .to receive(:verify_slack_signature)
          allow(SlackCheckoutActiveJob).to receive(:perform_later)
        end

        schema type: :object,
          properties: {
            response_type: { type: :string, enum: ["ephemeral"] },
            text: { type: :string }
          },
          required: %w[response_type text]

        it "returns the documented acknowledgement" do
          post "/slack/commands/checkout", params: command_details, headers: {
            "X-Slack-Signature" => public_send(:"X-Slack-Signature"),
            "X-Slack-Request-Timestamp" => public_send(:"X-Slack-Request-Timestamp")
          }

          expect(response).to have_http_status(:ok)
          expect(response.parsed_body).to match(
            "response_type" => "ephemeral",
            "text" => "Looking up your active checkouts..."
          )
        end
      end

      response "403", "Slack signature is missing, invalid, or stale" do
        schema type: :object,
          properties: { error: { type: :string } },
          required: ["error"]

        it "rejects a stale signed request" do
          allow(ENV).to receive(:[]).and_call_original
          allow(ENV).to receive(:[]).with("SLACK_SIGNING_SECRET").and_return("documented-secret")

          post "/slack/commands/checkout",
            params: { text: "active", user_id: "U12345678" },
            headers: {
              "X-Slack-Signature" => "v0=stale",
              "X-Slack-Request-Timestamp" => 10.minutes.ago.to_i.to_s
            }

          expect(response).to have_http_status(:forbidden)
          expect(response.parsed_body).to eq("error" => "Request too old")
        end
      end
    end
  end
end
