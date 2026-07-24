require "rails_helper"

RSpec.describe Service::ReservationSlackCanvas do
  let(:zone) { ReservationService::ZONE }
  let(:member) do
    create(
      :member,
      :current,
      firstname: "Ada",
      lastname: "Lovelace"
    )
  end
  let(:shop) { create(:shop, name: "Woodshop", slack_channel: "woodshop") }
  let(:tool) { create(:tool, shop: shop, name: "Planer") }

  before do
    allow(REDIS).to receive(:set).and_return(true)
    allow(REDIS).to receive(:eval).and_return(1)
    allow(Service::SlackConnector).to receive(:find_channel_id)
      .with("woodshop")
      .and_return("C123")
    allow(Service::SlackConnector).to receive(:create_canvas)
      .with("Today's Reservations")
      .and_return("FTODAY")
    allow(Service::SlackConnector).to receive(:create_canvas)
      .with("Tomorrow's Reservations")
      .and_return("FTOMORROW")
    allow(Service::SlackConnector).to receive(:set_canvas_channel_access)
    allow(Service::SlackConnector).to receive(:replace_canvas)
  end

  it "creates, shares, caches, and populates today's and tomorrow's canvases" do
    travel_to(zone.local(2026, 7, 24, 8, 15)) do
      create(
        :reservation,
        member: member,
        shop: shop,
        title: "Build cabinet",
        reservation_scope: "tools",
        tool_ids: [tool.id.to_s],
        start_at: zone.local(2026, 7, 24, 9, 0),
        end_at: zone.local(2026, 7, 24, 10, 30),
        status: "approved"
      )
      create(
        :reservation,
        member: create(:member, :current),
        shop: shop,
        title: "Safety class",
        start_at: zone.local(2026, 7, 25, 13, 0),
        end_at: zone.local(2026, 7, 25, 14, 0),
        status: "pending"
      )

      described_class.sync!(
        shop,
        dates: %w[2026-07-24 2026-07-25]
      )

      expect(shop.reload).to have_attributes(
        canvas_today: "FTODAY",
        canvas_tomorrow: "FTOMORROW"
      )
      expect(Service::SlackConnector).to have_received(:set_canvas_channel_access)
        .with("FTODAY", "C123")
      expect(Service::SlackConnector).to have_received(:set_canvas_channel_access)
        .with("FTOMORROW", "C123")
      expect(Service::SlackConnector).to have_received(:replace_canvas)
        .with(
          "FTODAY",
          a_string_including(
            "Build cabinet",
            "Ada Lovelace",
            "Planer",
            "09:00-10:30",
            "Approved"
          )
        )
      expect(Service::SlackConnector).to have_received(:replace_canvas)
        .with(
          "FTOMORROW",
          a_string_including("Safety class", "Entire shop", "Pending")
        )
    end
  end

  it "reuses a cached canvas ID instead of creating another canvas" do
    travel_to(zone.local(2026, 7, 24, 8, 15)) do
      shop.update!(canvas_today: "FEXISTING")

      described_class.sync!(shop, dates: ["2026-07-24"])

      expect(Service::SlackConnector).not_to have_received(:create_canvas)
        .with("Today's Reservations")
      expect(Service::SlackConnector).to have_received(:replace_canvas)
        .with("FEXISTING", a_string_including("No pending or approved reservations"))
    end
  end

  it "recreates a cached canvas that no longer exists in Slack" do
    travel_to(zone.local(2026, 7, 24, 8, 15)) do
      shop.update!(canvas_today: "FDELETED")
      attempts = 0
      allow(Service::SlackConnector).to receive(:set_canvas_channel_access) do
        attempts += 1
        if attempts == 1
          raise Slack::Web::Api::Errors::CanvasNotFound.new("canvas_not_found")
        end
      end

      described_class.sync!(shop, dates: ["2026-07-24"])

      expect(shop.reload.canvas_today).to eq("FTODAY")
      expect(Service::SlackConnector).to have_received(:create_canvas)
        .with("Today's Reservations")
      expect(Service::SlackConnector).to have_received(:replace_canvas)
        .with("FTODAY", a_string_including("Woodshop Reservations"))
    end
  end

  it "logs the configured channel when it cannot be resolved" do
    allow(Service::SlackConnector).to receive(:find_channel_id).and_return(nil)
    expect(Rails.logger).to receive(:error).with(
      a_string_including(
        "[ReservationSlackCanvasChannelNotFound]",
        "shop_id=#{shop.id}",
        'slack_channel="woodshop"'
      )
    )

    described_class.sync!(shop, dates: [Date.current])

    expect(Service::SlackConnector).not_to have_received(:create_canvas)
  end
end
