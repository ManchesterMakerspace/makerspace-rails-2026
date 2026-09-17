require "rails_helper"

RSpec.describe "Slack interactions", type: :request do
  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("SLACK_SIGNING_SECRET").and_return(nil)
    allow(CloudflareRails::Importer).to receive(:cloudflare_ips).and_return([])
  end

  it "rejects unsigned requests when the signing secret is absent" do
    post "/slack/interactions", params: { payload: "{}" }

    expect(response).to have_http_status(:forbidden)
    expect(JSON.parse(response.body)).to include(
      "error" => "Slack signing secret is not configured"
    )
  end

  it "allows the missing-secret bypass in development" do
    allow(Rails.env).to receive(:development?).and_return(true)

    post "/slack/interactions", params: { payload: "{}" }

    expect(response).to have_http_status(:ok)
  end

  context "with a checkout request submission" do
    let(:shop) { create(:shop) }
    let(:tool) { create(:tool, shop: shop, open: false) }
    let(:member) { create(:member, :current) }

    before do
      allow(Rails.env).to receive(:development?).and_return(true)
      SlackUser.create!(member: member, slack_id: "USUBMITTER")
      allow(Service::SlackConnector).to receive(:send_slack_message)
    end

    def submit(tool_id: tool.id.to_s, shop_id: shop.id.to_s, user_id: "USUBMITTER", note: nil)
      payload = {
        type: "view_submission", user: { id: user_id },
        view: {
          callback_id: "checkout_request_submit",
          private_metadata: { shop_id: shop_id }.to_json,
          state: { values: {
            tool: { tool: { selected_option: { value: tool_id } } },
            note: { note: { value: note } }
          } }
        }
      }
      post "/slack/interactions", params: { payload: payload.to_json }
    end

    it "creates and announces a request with its note, then confirms receipt" do
      allow_any_instance_of(ToolCheckoutRequest).to receive(:announce_request)
      submit(note: "Please show me the blade guard")

      expect(response.parsed_body).to eq("response_action" => "clear")
      expect(ToolCheckoutRequest.last).to have_attributes(member_id: member.id, tool_id: tool.id, note: "Please show me the blade guard")
      expect(Service::SlackConnector).to have_received(:send_slack_message).with(include("unpaid volunteers"), "USUBMITTER")
    end

    it "uses the submitting Slack identity instead of trusting metadata" do
      attacker = create(:member, :current)
      SlackUser.create!(member: attacker, slack_id: "UATTACKER")
      submit(user_id: "UATTACKER")

      expect(ToolCheckoutRequest.last.member_id).to eq(attacker.id)
    end

    it "clears the modal when confirmation delivery fails after creation" do
      allow(Service::SlackConnector).to receive(:send_slack_message).and_raise(StandardError, "Slack unavailable")
      allow(Service::ErrorReporter).to receive(:notify)

      submit

      expect(response.parsed_body).to eq("response_action" => "clear")
      expect(ToolCheckoutRequest.where(member_id: member.id, tool_id: tool.id, status: "open")).to exist
      expect(Service::ErrorReporter).to have_received(:notify).with(
        instance_of(StandardError),
        context: hash_including(phase: "Slack checkout request confirmation")
      )
    end

    it "rejects a tool tampered to belong to another shop" do
      other_tool = create(:tool, open: false)
      submit(tool_id: other_tool.id.to_s)

      expect(response.parsed_body).to include("response_action" => "errors")
      expect(ToolCheckoutRequest.count).to eq(0)
    end

    it "returns a field error for duplicate submissions" do
      ToolCheckoutRequest.create!(member: member, tool: tool)
      submit

      expect(response.parsed_body.dig("errors", "tool")).to include("already have an open request")
    end

    it "returns the model's note validation as a Block Kit field error" do
      submit(note: "x" * 129)

      expect(response.parsed_body.dig("errors", "note")).to include("too long")
      expect(ToolCheckoutRequest.count).to eq(0)
    end
  end

  context "with a reservation interaction" do
    let(:member) { create(:member, :current) }
    let(:response_url) { "https://hooks.slack.test/responses/secret" }
    let(:metadata) do
      { member_id: member.id.to_s, shop_id: BSON::ObjectId.new.to_s,
        response_url: response_url, slack_user_id: "UINITIATOR" }
    end

    before do
      allow(Rails.env).to receive(:development?).and_return(true)
      allow(Service::ErrorReporter).to receive(:notify)
      allow(Service::SlackConnector).to receive(:send_slack_message)
    end

    def reservation_payload(type: "view_submission", date: "2027-01-02", start_time: "10:00", duration: "hours:1.0")
      {
        type: type, user: { id: "USUBMITTER" },
        view: {
          callback_id: "reservation_submit", private_metadata: metadata.to_json,
          state: { values: {
            title: { title: { value: "Lathe time" } },
            scope: { SlackReservationModal::SCOPE_ACTION_ID => { selected_option: { value: "shop" } } },
            date: { date: { selected_date: date } },
            start_time: { start_time: { selected_time: start_time } },
            duration: { duration: { selected_option: { value: duration } } }
          } }
        }
      }
    end

    it "converts a selected duration into the reservation end time" do
      reservation = instance_double(Reservation, title: "Lathe time", status: "approved")
      expect(ReservationService).to receive(:create!) do |arguments|
        attributes = arguments.fetch(:attributes)
        expect(attributes[:start_at]).to eq(ReservationService::ZONE.parse("2027-01-02 10:00"))
        expect(attributes[:end_at]).to eq(ReservationService::ZONE.parse("2027-01-02 12:30"))
        expect(attributes[:full_day]).to be(false)
        reservation
      end
      post "/slack/interactions", params: {
        payload: reservation_payload(duration: "hours:2.5").to_json
      }

      expect(response.parsed_body).to eq("response_action" => "clear")
    end

    it "advances whole-day durations across daylight-saving changes by local dates" do
      reservation = instance_double(Reservation, title: "Lathe time", status: "approved")
      expect(ReservationService).to receive(:create!) do |arguments|
        attributes = arguments.fetch(:attributes)
        expect(attributes[:start_at].in_time_zone(ReservationService::ZONE)).to eq(
          ReservationService::ZONE.local(2027, 3, 14)
        )
        expect(attributes[:end_at].in_time_zone(ReservationService::ZONE)).to eq(
          ReservationService::ZONE.local(2027, 3, 15)
        )
        expect(attributes[:end_at] - attributes[:start_at]).to eq(23.hours)
        expect(attributes[:full_day]).to be(true)
        reservation
      end
      post "/slack/interactions", params: {
        payload: reservation_payload(date: "2027-03-14", duration: "days:1").to_json
      }

      expect(response.parsed_body).to eq("response_action" => "clear")
    end

    it "returns an error on the duration block when server policy rejects the duration" do
      expect(ReservationService).to receive(:create!)
        .and_raise(Error::UnprocessableEntity.new("Reservation exceeds the maximum duration"))

      post "/slack/interactions", params: {
        payload: reservation_payload(duration: "hours:9.0").to_json
      }

      expect(response.parsed_body).to include(
        "response_action" => "errors",
        "errors" => { "duration" => "Reservation exceeds the maximum duration" }
      )
    end

    {
      "A title is required" => "title",
      "Reservation date is outside the booking window" => "date",
      "Start time does not satisfy advance notice" => "start_time",
      "The selected resource is not reservable" => "scope"
    }.each do |message, block_id|
      it "puts #{block_id} policy errors beside the relevant field" do
        allow(ReservationService).to receive(:create!)
          .and_raise(Error::UnprocessableEntity.new(message))

        post "/slack/interactions", params: { payload: reservation_payload.to_json }

        expect(response.parsed_body).to include(
          "response_action" => "errors",
          "errors" => { block_id => message }
        )
      end
    end

    it "shows broad fee confirmation failures in a modal alert" do
      shop = instance_double(Shop)
      updated_view = { type: "modal", submit: { type: "plain_text", text: "Use Member Portal" } }
      allow(ReservationService).to receive(:create!).and_raise(
        Error::UnprocessableEntity.new("Please review and approve the reservation fee of $12.50")
      )
      allow(Shop).to receive(:find).with(metadata[:shop_id]).and_return(shop)
      expect(SlackReservationModal).to receive(:update).with(hash_including(
        shop: shop,
        alert_message: include("$12.50")
      )).and_return(updated_view)

      post "/slack/interactions", params: { payload: reservation_payload.to_json }

      expect(response.parsed_body).to eq(
        "response_action" => "update",
        "view" => updated_view.deep_stringify_keys
      )
    end

    it "rebuilds the modal policy and preserves state after resource block actions" do
      shop = instance_double(Shop)
      rebuilt_view = { type: "modal", blocks: [] }
      allow(Shop).to receive(:find).with(metadata[:shop_id]).and_return(shop)
      allow(Member).to receive(:find).with(member.id.to_s).and_return(member)
      expect(SlackReservationModal).to receive(:update).with(
        shop: shop,
        member: member,
        read_context: instance_of(ReservationReadContext),
        response_url: response_url,
        slack_user_id: "UINITIATOR",
        reservation_scope: "shop",
        tool_ids: [],
        title: "Lathe time",
        date: "2027-01-02",
        start_time: "10:00",
        duration: "hours:1.0"
      ).and_return(rebuilt_view)
      expect(Service::SlackConnector).to receive(:update_modal)
        .with("V123", rebuilt_view, hash: "view-hash")
      payload = reservation_payload(type: "block_actions")
      payload[:view][:id] = "V123"
      payload[:view][:hash] = "view-hash"
      payload[:actions] = [{
        action_id: SlackReservationModal::SCOPE_ACTION_ID,
        selected_option: { value: "shop" }
      }]

      post "/slack/interactions", params: { payload: payload.to_json }

      expect(response.parsed_body).to eq({})
    end

    it "re-resolves added tools and applies their strictest rules" do
      shop = create(:shop, max_reservation_duration_hours: 8)
      first = create(:tool, shop: shop, open: true, max_reservation_duration_hours: 8)
      strict = create(:tool, shop: shop, max_reservation_duration_hours: 3,
        reservation_horizon_days: 2, minimum_advance_notice_hours: 6, open: true)
      payload = reservation_payload(type: "block_actions", duration: "hours:8")
      payload[:view][:private_metadata] = metadata.merge(shop_id: shop.id.to_s).to_json
      payload[:view][:id] = "VADD"
      payload[:view][:state][:values][:scope][SlackReservationModal::SCOPE_ACTION_ID][:selected_option][:value] = "tools"
      payload[:actions] = [{
        action_id: SlackReservationModal::TOOLS_ACTION_ID,
        selected_options: [first, strict].map { |tool| { value: tool.id.to_s } }
      }]
      expect(Service::SlackConnector).to receive(:update_modal) do |_id, view, hash:|
        duration = view[:blocks].find { |candidate| candidate[:block_id] == "duration" }
        details = view[:blocks].find { |candidate| candidate[:block_id] == "reservation_policy_details" }
        expect(duration.dig(:element, :initial_option, :value)).to eq("hours:3.0")
        expect(details.dig(:text, :text)).to include("2 days", "6 hours", first.name, strict.name)
        expect(hash).to be_nil
      end

      post "/slack/interactions", params: { payload: payload.to_json }

      expect(response.parsed_body).to eq({})
    end

    it "preserves an empty tool selection after all tools are removed" do
      shop = create(:shop)
      create(:tool, shop: shop, open: true)
      payload = reservation_payload(type: "block_actions")
      payload[:view][:private_metadata] = metadata.merge(shop_id: shop.id.to_s).to_json
      payload[:view][:id] = "VREMOVE"
      payload[:view][:state][:values][:scope][SlackReservationModal::SCOPE_ACTION_ID][:selected_option][:value] = "tools"
      payload[:actions] = [{ action_id: SlackReservationModal::TOOLS_ACTION_ID, selected_options: [] }]
      expect(Service::SlackConnector).to receive(:update_modal) do |_id, view, hash:|
        expect(view.dig(:submit, :text)).to eq("Review selection")
        expect(view[:blocks].find { |candidate| candidate[:block_id] == "reservation_policy_details" }
          .dig(:text, :text)).to include("Select one or more tools")
        expect(hash).to be_nil
      end

      post "/slack/interactions", params: { payload: payload.to_json }

      expect(response.parsed_body).to eq({})
    end

    it "rejects stale, disabled, non-reservable, and cross-shop tool IDs" do
      shop = create(:shop)
      allow(Service::SlackConnector).to receive(:update_modal)
      invalid_tools = [
        BSON::ObjectId.new.to_s,
        create(:tool, shop: shop, disabled: true).id.to_s,
        create(:tool, shop: shop, reservable: false).id.to_s,
        create(:tool).id.to_s
      ]

      invalid_tools.each do |tool_id|
        payload = reservation_payload(type: "block_actions")
        payload[:view][:private_metadata] = metadata.merge(shop_id: shop.id.to_s).to_json
        payload[:actions] = [{
          action_id: SlackReservationModal::TOOLS_ACTION_ID,
          selected_options: [{ value: tool_id }]
        }]
        post "/slack/interactions", params: { payload: payload.to_json }
        expect(response.parsed_body).to eq({})
      end

      expect(Service::SlackConnector).not_to have_received(:update_modal)
      expect(Service::ErrorReporter).to have_received(:notify).at_least(:once).with(
        instance_of(Error::UnprocessableEntity),
        context: hash_including(phase: "Slack reservation modal policy update")
      )
    end

    it "reports views.update failures without accepting submitted option data" do
      shop = create(:shop)
      tool = create(:tool, shop: shop, open: true)
      payload = reservation_payload(type: "block_actions")
      payload[:view][:private_metadata] = metadata.merge(shop_id: shop.id.to_s).to_json
      payload[:actions] = [{
        action_id: SlackReservationModal::TOOLS_ACTION_ID,
        selected_options: [{ value: tool.id.to_s, text: { text: "Forged name" } }]
      }]
      allow(Service::SlackConnector).to receive(:update_modal).and_raise(StandardError, "Slack unavailable")

      post "/slack/interactions", params: { payload: payload.to_json }

      expect(response.parsed_body).to eq({})
      expect(Service::ErrorReporter).to have_received(:notify).with(
        instance_of(StandardError),
        context: hash_including(phase: "Slack reservation modal policy update")
      )
    end

    it "prevents submission for incompatible horizon and notice selections" do
      shop = create(:shop)
      horizon = create(:tool, shop: shop, name: "Today Only", reservation_horizon_days: 0, open: true)
      notice = create(:tool, shop: shop, name: "Tomorrow Only", prohibit_same_day_reservations: true, open: true)
      payload = reservation_payload(type: "block_actions")
      payload[:view][:private_metadata] = metadata.merge(shop_id: shop.id.to_s).to_json
      payload[:view][:state][:values][:scope][SlackReservationModal::SCOPE_ACTION_ID][:selected_option][:value] = "tools"
      payload[:actions] = [{
        action_id: SlackReservationModal::TOOLS_ACTION_ID,
        selected_options: [horizon, notice].map { |tool| { value: tool.id.to_s } }
      }]
      expect(Service::SlackConnector).to receive(:update_modal) do |_id, view, hash:|
        expect(view.dig(:submit, :text)).to eq("Review selection")
        text = view[:blocks].find { |candidate| candidate[:block_id] == "reservation_policy_details" }.dig(:text, :text)
        expect(text).to include("Unavailable combination", "Today Only", "Tomorrow Only")
        expect(hash).to be_nil
      end

      post "/slack/interactions", params: { payload: payload.to_json }
    end

    it "rejects an incompatible tool combination against the tools input before creation" do
      shop = create(:shop)
      horizon = create(:tool, shop: shop, reservation_horizon_days: 0, open: true)
      notice = create(:tool, shop: shop, prohibit_same_day_reservations: true, open: true)
      payload = reservation_payload
      payload[:view][:private_metadata] = metadata.merge(shop_id: shop.id.to_s).to_json
      payload[:view][:state][:values][:scope][SlackReservationModal::SCOPE_ACTION_ID][:selected_option][:value] = "tools"
      payload[:view][:state][:values][:tools] = {
        SlackReservationModal::TOOLS_ACTION_ID => {
          selected_options: [horizon, notice].map { |tool| { value: tool.id.to_s } }
        }
      }
      expect(ReservationService).not_to receive(:create!)

      post "/slack/interactions", params: { payload: payload.to_json }

      expect(response.parsed_body).to include(
        "response_action" => "errors",
        "errors" => include("tools" => include("cannot be reserved together"))
      )
    end

    it "queues approved outcome delivery before clearing the modal" do
      reservation = instance_double(Reservation, title: "Lathe time", status: "approved")
      allow(ReservationService).to receive(:create!).and_return(reservation)

      post "/slack/interactions", params: { payload: reservation_payload.to_json }

      expect(response.parsed_body).to eq("response_action" => "clear")
      expect(SlackReservationOutcomeJob).to have_been_enqueued.with(
        include("approved"), response_url, "USUBMITTER"
      )
    end

    { "pending" => "pending approval", "unpaid" => "payment is required",
      "approved" => "approved" }.each do |status, text|
      it "uses the #{status} reservation outcome text" do
        details = status == "pending" ? [{ "message" => "Manager review" }] : []
        reservation = instance_double(
          Reservation, title: "Lathe time", status: status,
          effective_approval_details: details
        )
        allow(ReservationService).to receive(:create!).and_return(reservation)

        post "/slack/interactions", params: { payload: reservation_payload.to_json }
        expect(response.parsed_body).to eq("response_action" => "clear")
        expect(SlackReservationOutcomeJob).to have_been_enqueued.with(
          include(text), response_url, "USUBMITTER"
        )
      end
    end

    it "queues modal closure outcome delivery" do
      expect(ReservationService).not_to receive(:create!)

      post "/slack/interactions", params: { payload: reservation_payload(type: "view_closed").to_json }

      expect(response.parsed_body).to eq({})
      expect(SlackReservationOutcomeJob).to have_been_enqueued.with(
        include("cancelled without submission"), response_url, "USUBMITTER"
      )
    end

    it "clears the modal after creation even when outcome enqueueing fails" do
      reservation = instance_double(Reservation, title: "Lathe time", status: "approved")
      expect(ReservationService).to receive(:create!).and_return(reservation)
      allow(SlackReservationOutcomeJob).to receive(:perform_later).and_raise(StandardError, "queue unavailable")

      post "/slack/interactions", params: { payload: reservation_payload.to_json }

      expect(response.parsed_body).to eq("response_action" => "clear")
      expect(Service::ErrorReporter).to have_received(:notify).with(
        instance_of(StandardError), context: hash_including(phase: "Slack reservation outcome delivery")
      )
    end
  end
end
