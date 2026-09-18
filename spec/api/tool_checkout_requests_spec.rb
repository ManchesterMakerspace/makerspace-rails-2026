require "swagger_helper"

describe "Tool checkout requests API", type: :request do
  before do
    allow(REDIS).to receive(:set).and_return(true)
    allow(REDIS).to receive(:eval).and_return(1)
  end

  path "/tool_checkout_requests" do
    get "Lists the member's eligible open checkout requests" do
      tags "ToolCheckoutRequests"
      description "Returns open requests for enabled tools belonging to the signed-in member. Excludes inactive, expired, revoked and suspended members; pending members require a tool allowing pending members. Defaults to request_date then id ascending."
      produces "application/json"
      response "200", "eligible open requests" do
        let(:member) { create(:member, :current) }
        let(:tool) { create(:tool) }
        let!(:visible_request) { ToolCheckoutRequest.create!(member: member, tool: tool) }
        before do
          ToolCheckoutRequest.create!(member: create(:member, :current, status: "suspended"), tool: tool)
          sign_in member
        end
        schema type: :array, items: { type: :object }
        run_test! do |response|
          expect(JSON.parse(response.body).map { |row| row.fetch("id") }).to eq([visible_request.id.to_s])
        end
      end
    end

    post "Requests a safety checkout" do
      tags "ToolCheckoutRequests"
      operationId "createToolCheckoutRequest"
      description "Creation is serialized under the shared per-member/tool lock, with membership, availability, prerequisites, checkout records and open requests rechecked immediately before insertion. Lock contention returns 422."
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


describe "Checkout approval queue API", type: :request do
  path "/admin/tool_checkout_requests" do
    get "Lists authorized eligible open checkout requests" do
      tags "ToolCheckoutRequests"
      description "Admins and board members see all tool scopes; resource managers see managed shops; valid checkout approvers see assigned enabled tools and shops. All scopes exclude inactive, expired, revoked and suspended requesters. Pending requesters require a tool allowing pending members. Defaults to request_date then id ascending."
      produces "application/json"
      response "200", "authorized open requests" do
        let(:member) { create(:member, :current, role: "admin") }
        let(:tool) { create(:tool) }
        let!(:visible_request) { ToolCheckoutRequest.create!(member: member, tool: tool) }
        before do
          ToolCheckoutRequest.create!(member: create(:member, :current, status: "suspended"), tool: tool)
          sign_in member
        end
        schema type: :array, items: { type: :object }
        run_test! do |response|
          expect(JSON.parse(response.body).map { |row| row.fetch("id") }).to eq([visible_request.id.to_s])
        end
      end
    end
  end
end


describe "Checkout request mutations API", type: :request do
  let(:member) { create(:member, :current) }
  let(:tool) { create(:tool) }
  let(:row) { ToolCheckoutRequest.create!(member: member, tool: tool) }
  let(:id) { row.id.to_s }
  before do
    sign_in member
    allow(REDIS).to receive(:set).and_return(true)
    allow(REDIS).to receive(:eval).and_return(1)
    allow_any_instance_of(ToolCheckoutRequest).to receive(:remove_announcement)
  end
  path "/tool_checkout_requests/{id}" do
    parameter name: :id, in: :path, type: :string
    put "Edits an owned open request note" do
      tags "ToolCheckoutRequests"
      description "Owner and open status are rechecked inside the same member/tool lock used by approval and cancellation. Tool and shop must still be available."
      consumes "application/json"
      produces "application/json"
      parameter name: :details, in: :body, schema: { type: :object, properties: { note: { type: :string, maxLength: 128 } } }
      let(:details) { { note: "Updated note" } }
      response "200", "note updated" do
        schema type: :object
        run_test! { expect(row.reload.note).to eq("Updated note") }
      end
      response "403", "request is no longer open or not owned by the caller" do
        before { row.update!(status: "closed") }
        schema "$ref" => "#/components/schemas/error"
        run_test!
      end
      response "422", "note validation or checkout lock contention" do
        let(:details) { { note: "x" * 129 } }
        schema "$ref" => "#/components/schemas/error"
        run_test!
      end
    end
    delete "Cancels an owned open request" do
      tags "ToolCheckoutRequests"
      description "Cancellation and approval serialize under the same member/tool lock. A successful cancellation retains the existing announcement-removal behavior."
      produces "application/json"
      response "204", "request cancelled" do
        run_test! { expect(row.reload.status).to eq("deleted") }
      end
      response "403", "request is no longer open or not owned by the caller" do
        before { row.update!(status: "closed") }
        schema "$ref" => "#/components/schemas/error"
        run_test!
      end
      response "422", "another checkout mutation holds the lock" do
        before { allow(REDIS).to receive(:set).and_return(false) }
        schema "$ref" => "#/components/schemas/error"
        run_test!
      end
    end
  end
end
