require "rails_helper"

RSpec.describe Service::ReservationSlackCanvas, ".ensure_today_for_announcement!" do
  let(:zone) { ReservationService::ZONE }
  let(:shop) { create(:shop, name: "Woodshop", slack_channel: "woodshop") }

  before do
    allow(REDIS).to receive(:set).and_return(true)
    allow(REDIS).to receive(:eval).and_return(1)
    allow(Service::SlackConnector).to receive(:message_destination_mode).and_return("production")
    allow(Service::SlackConnector).to receive(:create_canvas).and_return("FFRESH")
    allow(Service::SlackConnector).to receive(:set_canvas_channel_access)
    allow(Service::SlackConnector).to receive(:set_canvas_user_access)
    allow(Service::SlackConnector).to receive(:replace_canvas)
    allow(Service::SlackConnector).to receive(:find_channel_id).with("#woodshop").and_return("CSHOP")
    allow(Service::SlackConnector).to receive(:resolved_channel_id).and_return("CTEST")
  end

  def ensure_agenda(mode: "production", channel: "CTOOL")
    described_class.ensure_today_for_announcement!(shop, channel_id: channel,
      date: Time.current.in_time_zone(zone).to_date, mode: mode)
  end

  it "creates an empty shop agenda and shares it with both announcement and shop channels" do
    travel_to(zone.local(2026, 7, 24, 7)) do
      expect(ensure_agenda).to eq("FFRESH")
    end

    expect(shop.reload.canvas_today).to eq("FFRESH")
    expect(Service::SlackConnector).to have_received(:set_canvas_channel_access).with("FFRESH", "CTOOL")
    expect(Service::SlackConnector).to have_received(:set_canvas_channel_access).with("FFRESH", "CSHOP")
    expect(Service::SlackConnector).to have_received(:replace_canvas)
      .with("FFRESH", a_string_including("Friday, July 24, 2026", "No pending or approved reservations"))
  end

  it "supports a tool-users destination when the shop has no configured channel" do
    shop.set(slack_channel: nil)
    travel_to(zone.local(2026, 7, 24, 7)) { expect(ensure_agenda).to eq("FFRESH") }
    expect(Service::SlackConnector).not_to have_received(:find_channel_id)
    expect(Service::SlackConnector).to have_received(:set_canvas_channel_access).once.with("FFRESH", "CTOOL")
  end

  it "refreshes the existing rolling canvas after day rollover before returning it" do
    shop.set(canvas_today: "FEXISTING")
    travel_to(zone.local(2026, 7, 25, 7)) { expect(ensure_agenda).to eq("FEXISTING") }
    expect(Service::SlackConnector).not_to have_received(:create_canvas)
    expect(Service::SlackConnector).to have_received(:replace_canvas)
      .with("FEXISTING", a_string_including("Saturday, July 25, 2026"))
  end

  it "recreates a deleted cached canvas and returns the replacement ID" do
    shop.set(canvas_today: "FDELETED")
    allow(Service::SlackConnector).to receive(:replace_canvas).with("FDELETED", anything)
      .and_raise(Slack::Web::Api::Errors::CanvasDeleted.new("canvas_deleted"))
    travel_to(zone.local(2026, 7, 24, 7)) { expect(ensure_agenda).to eq("FFRESH") }
    expect(shop.reload.canvas_today).to eq("FFRESH")
    expect(Service::SlackConnector).to have_received(:replace_canvas).with("FFRESH", kind_of(String))
  end

  it "uses an isolated test canvas and grants no real shop-channel access" do
    shop.set(canvas_today: "FPRODUCTION", canvas_tomorrow: "FPRODUCTION-TOMORROW")
    allow(Service::SlackConnector).to receive(:message_destination_mode).and_return("test")
    travel_to(zone.local(2026, 7, 24, 7)) { expect(ensure_agenda(mode: "test", channel: "CTEST")).to eq("FFRESH") }
    expect(shop.reload).to have_attributes(canvas_today: "FPRODUCTION", canvas_tomorrow: "FPRODUCTION-TOMORROW",
      announcement_test_canvas_today: "FFRESH")
    expect(Service::SlackConnector).to have_received(:create_canvas).with("Today's Woodshop Reservations (Test)")
    expect(Service::SlackConnector).to have_received(:set_canvas_channel_access).once.with("FFRESH", "CTEST")
    expect(Service::SlackConnector).not_to have_received(:find_channel_id)
    expect(Service::SlackConnector).not_to have_received(:replace_canvas).with("FPRODUCTION", anything)
    expect(Service::SlackConnector).not_to have_received(:set_canvas_user_access).with(anything, array_including(kind_of(String)), anything)
  end

  it "refuses to use a production canvas from a test destination mode" do
    allow(Service::SlackConnector).to receive(:message_destination_mode).and_return("test")
    expect { ensure_agenda }.to raise_error(ArgumentError, /destination mode/)
    expect(Service::SlackConnector).not_to have_received(:create_canvas)
  end

  it "refuses a real channel even when the requested canvas mode is test" do
    allow(Service::SlackConnector).to receive(:message_destination_mode).and_return("test")
    expect { ensure_agenda(mode: "test", channel: "CREAL") }.to raise_error(ArgumentError, /redirected test channel/)
    expect(Service::SlackConnector).not_to have_received(:create_canvas)
  end

  it "does not return a cached ID when publishing fails" do
    shop.set(canvas_today: "FEXISTING")
    allow(Service::SlackConnector).to receive(:replace_canvas).and_raise(StandardError, "Slack unavailable")
    expect { ensure_agenda }.to raise_error(StandardError, "Slack unavailable")
  end

  [8, 20].each do |hour|
    it "rejects Eastern yesterday without changing a canvas at #{hour}:00 Eastern" do
      travel_to(zone.local(2026, 11, 20, hour)) do
        yesterday = Time.current.in_time_zone(zone).to_date - 1.day
        expect do
          described_class.ensure_today_for_announcement!(shop, channel_id: "CTOOL", date: yesterday, mode: "production")
        end.to raise_error(ArgumentError, /date must be today/)
      end
      expect(Service::SlackConnector).not_to have_received(:replace_canvas)
    end
  end

  it "accepts Eastern today after UTC has rolled into the next date" do
    Time.use_zone('UTC') do
      travel_to(zone.local(2026, 11, 20, 20)) do
        expect(Date.current).to eq(Date.new(2026, 11, 21))
        expect(ensure_agenda).to eq('FFRESH')
        expect(Service::SlackConnector).to have_received(:replace_canvas)
          .with('FFRESH', a_string_including('Friday, November 20, 2026'))
      end
    end
  end
end
