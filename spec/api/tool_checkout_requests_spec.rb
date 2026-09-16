require "swagger_helper"

describe "Tool checkout requests API", type: :request do
  path "/tool_checkout_requests" do
    post "Requests a safety checkout" do
      tags "ToolCheckoutRequests"
      operationId "createToolCheckoutRequest"
      consumes "application/json"
      produces "application/json"
      parameter name: :request_details, in: :body, schema: {
        type: :object,
        properties: {
          tool_id: { type: :string },
          note: { type: :string }
        },
        required: ["tool_id"]
      }

      response "200", "checkout request created" do
        let(:member) { create(:member, :current) }
        let(:tool) { create(:tool) }
        let(:request_details) { { tool_id: tool.id.to_s, note: "Please train me" } }
        before do
          sign_in member
          allow_any_instance_of(ToolCheckoutRequest).to receive(:announce_request)
        end

        schema type: :object,
          properties: {
            id: { type: :string },
            memberId: { type: :string },
            memberName: { type: :string },
            memberEmail: { type: :string },
            memberStatus: { type: :string },
            toolId: { type: :string },
            toolName: { type: :string },
            shopId: { type: :string },
            shopName: { type: :string },
            note: { type: :string, nullable: true },
            requestDate: { type: :string, format: "date-time" },
            status: { type: :string },
            messageId: { type: :string, nullable: true },
            checkedOutId: { type: :string, nullable: true },
            memberSlackUrl: { type: :string, nullable: true }
          },
          required: %w[
            id memberId memberName memberEmail memberStatus toolId toolName
            shopId shopName note requestDate status messageId checkedOutId memberSlackUrl
          ]
        run_test!
      end

      response "422", "tool is not eligible, prerequisites are unmet, or a record/request exists" do
        schema "$ref" => "#/components/schemas/error"

        context "with an unmet prerequisite" do
          let(:member) { create(:member, :current) }
          let(:prerequisite) { create(:tool) }
          let(:tool) { create(:tool, shop: prerequisite.shop, prerequisite_ids: [prerequisite.id.to_s]) }
          let(:request_details) { { tool_id: tool.id.to_s } }
          before { sign_in member }

          run_test!
        end

        context "with a revoked checkout for the requested tool" do
          let(:member) { create(:member, :current) }
          let(:tool) { create(:tool) }
          let(:request_details) { { tool_id: tool.id.to_s } }
          before do
            create(:tool_checkout, member: member, tool: tool, revoked_at: Time.current)
            sign_in member
          end

          run_test!
        end
      end

      response "403", "membership is not eligible to request a checkout" do
        let(:member) { create(:member, :inactive) }
        let(:tool) { create(:tool, open: false) }
        let(:request_details) { { tool_id: tool.id.to_s } }
        before { sign_in member }

        schema "$ref" => "#/components/schemas/error"
        run_test!
      end
    end
  end
end
