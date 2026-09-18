require "swagger_helper"

describe "Slack interactions API", type: :request do
  path "/slack/interactions" do
    post "Handles signed Slack modal interactions",
      operation: { servers: [{ url: "/", description: "Application root" }] } do
      tags "SlackInteractions"
      operationId "slackInteractions"
      description "Callbacks: checkout_modal accepts block_actions and view_submission; checkout_request_submit accepts legacy submissions; reservation_submit also accepts view_closed. Checkout navigation calls views.update with the incoming view hash. Submissions return response_action update with a replacement modal, or errors keyed by input block ID. Checkout private_metadata is a signed, expiring contract containing member_id, optional shop_id, response_url, slack_user_id, step and optional record_id. Every transition reloads and authorizes these IDs. Display text is never an identifier. Checkout action IDs: checkout_menu_select, checkout_shop_select, checkout_tool_select, checkout_request_select, checkout_checkout_select, checkout_edit_note, checkout_cancel_request, checkout_approve_request, checkout_back. Note input block/action ID: checkout_note."
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
              "view_closed, and block_actions; checkout_modal accepts block_actions and view_submission. Block actions include actions and current view state. Checkout field errors use checkout_note.",
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
          description: "Empty acknowledgement, modal clear action, field validation errors, or a modal update containing a checkout/reservation view or explanatory alert",
          properties: {
            response_action: { type: :string, enum: %w[clear update errors] },
            errors: { type: :object, additionalProperties: { type: :string }, description: "Input block ID to validation message, including checkout_note" },
            view: { type: :object, properties: {
              type: { type: :string, enum: ["modal"] },
              callback_id: { type: :string, enum: %w[checkout_modal checkout_request_submit reservation_submit] },
              private_metadata: { type: :string },
              blocks: { type: :array, items: { type: :object } }
            }, required: %w[type callback_id blocks] }
          }, additionalProperties: true

        it "documents and acknowledges view closure payloads" do
          post "/slack/interactions", params: interaction, headers: {
            "X-Slack-Signature" => public_send(:"X-Slack-Signature"),
            "X-Slack-Request-Timestamp" => public_send(:"X-Slack-Request-Timestamp")
          }

          expect(response).to have_http_status(:ok)
          expect(response.parsed_body).to eq({})
        end

        context "with checkout modal callbacks" do
          let(:member) { create(:member, :current) }
          let(:shop) { create(:shop) }
          let(:tool) { create(:tool, shop: shop) }
          before do
            SlackUser.create!(member: member, slack_id: "UCHECKOUT")
            allow(Service::SlackConnector).to receive(:update_modal)
          end

          def checkout_view(step: "menu", record_id: nil)
            metadata = { "member_id" => member.id.to_s, "shop_id" => shop.id.to_s,
              "slack_user_id" => "UCHECKOUT", "step" => step, "record_id" => record_id }.compact
            SlackCheckoutModal.new(member: member, shop: shop, tool: tool, metadata: metadata).build
              .merge(id: "VCHECKOUT", hash: "current-hash")
          end

          it "acknowledges checkout block_actions and updates the modal with its hash" do
            payload = { type: "block_actions", user: { id: "UCHECKOUT" }, view: checkout_view,
              actions: [{ action_id: "checkout_menu_select", block_id: "checkout_menu",
                selected_option: { value: "active" } }] }
            post "/slack/interactions", params: { payload: payload.to_json }
            expect(response.parsed_body).to eq({})
            expect(Service::SlackConnector).to have_received(:update_modal).with("VCHECKOUT", hash_including(callback_id: "checkout_modal"), hash: "current-hash")
          end

          it "returns checkout submission field errors keyed by block ID" do
            view = checkout_view(step: "request_new", record_id: tool.id.to_s)
            view[:state] = { values: { checkout_note: { checkout_note: { value: "x" * 129 } } } }
            post "/slack/interactions", params: { payload: { type: "view_submission", user: { id: "UCHECKOUT" }, view: view }.to_json }
            expect(response.parsed_body).to include("response_action" => "errors", "errors" => { "checkout_note" => "Note must be at most 128 characters." })
          end

          it "returns a modal update explaining authorization changes" do
            view = checkout_view(step: "request_new", record_id: tool.id.to_s)
            member.update!(status: "inactive")
            post "/slack/interactions", params: { payload: { type: "view_submission", user: { id: "UCHECKOUT" }, view: view }.to_json }
            expect(response.parsed_body).to include("response_action" => "update", "view" => hash_including("callback_id" => "checkout_modal"))
            expect(response.parsed_body.dig("view", "blocks").to_json).to include("inactive")
          end
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
