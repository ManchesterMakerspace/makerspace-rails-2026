require 'rails_helper'

# Explicit opt-in; uses the normal disposable database safety/cleanup hooks.
RSpec.describe 'Eventbrite and announcement read benchmark', :benchmark do
  include ReservationReadMeasurement

  before do
    ActiveJob::Base.queue_adapter = :test
    allow(Service::MemberProvisioning).to receive(:invite_slack)
    allow(EventbriteIntegration::Configuration).to receive(:organization_ids).and_return(['benchmark'])
  end

  def report(operation, size, cache: 'live')
    samples = Array.new(5) { measure_reservation_reads { yield } }
    elapsed = samples.map { |sample| sample[:elapsed_ms] }.sort
    database = samples.map { |sample| sample[:database_ms] }.sort
    puts "QUERY_READ_BENCHMARK #{JSON.generate(operation: operation, size: size, cache: cache,
      reads: samples.map { |sample| sample[:commands].length }.uniq,
      collections: samples.first[:commands].tally.transform_keys { |key| key.join(':') },
      returned_bytes: samples.map { |sample| sample[:returned_bytes] }.uniq,
      returned_documents: samples.map { |sample| sample[:returned_documents] }.uniq,
      p50_ms: elapsed[2].round(2), p95_ms: elapsed[4].round(2),
      database_p50_ms: database[2].round(2), database_p95_ms: database[4].round(2), slack_network: 'mocked')}"
    samples
  end

  [1, 50].each do |size|
    it "measures Eventbrite history presentation with #{size} rows" do
      parent = EventbriteEvent.create!(organization_id: 'benchmark', eventbrite_id: 'event', name: 'Workshop',
        starts_at: Time.utc(2026, 11, 20, 15), timezone: 'America/New_York',
        summary: 'Description ' * 500, slack_receipts: { 'previous' => { 'ts' => '123.456', 'channel' => 'COLD00001' } })
      EventbriteTicketClass.create!(organization_id: 'benchmark', eventbrite_id: 'ticket', event_id: 'event', name: 'Admission')
      member = create(:member, :current)
      size.times do |number|
        EventbriteOrder.create!(organization_id: 'benchmark', eventbrite_id: "order#{number}", event_id: parent.eventbrite_id)
        EventbriteAttendee.create!(organization_id: 'benchmark', eventbrite_id: "attendee#{number}",
          event_id: 'event', order_id: "order#{number}", ticket_class_id: 'ticket', member_id: member.id)
      end
      %w[orders attendees].each do |kind|
        controller = Admin::EventbriteController.new
        controller.params = ActionController::Parameters.new(kind: kind)
        controller.response = ActionDispatch::TestResponse.new
        allow(controller).to receive(:render)
        if defined?(EventbriteIntegration::DisplayCache)
          EventbriteIntegration::DisplayCache.invalidate_all
        end
        cold = measure_reservation_reads { controller.index }
        puts "QUERY_READ_BENCHMARK #{JSON.generate(operation: "eventbrite_#{kind}", size: size, cache: 'cold',
          reads: cold[:commands].length, returned_bytes: cold[:returned_bytes],
          returned_documents: cold[:returned_documents], elapsed_ms: cold[:elapsed_ms].round(2))}"
        report("eventbrite_#{kind}", size, cache: 'warm') { controller.index }
      end
    end

    it "measures canvas rendering with #{size} reservation rows" do
      date = Date.new(2026, 11, 20)
      shop = create(:shop, name: 'Benchmark', slack_channel: 'CBENCH0001')
      member = create(:member, :current)
      tool = create(:tool, shop: shop, name: 'Benchmark saw')
      Reservation.collection.insert_many(Array.new(size) do |number|
        Reservation.new(member: member, shop: shop, title: "Benchmark #{number}", reservation_scope: 'tools',
          tool_ids: [tool.id.to_s], start_at: ReservationService::ZONE.local(2026, 11, 20, 10),
          end_at: ReservationService::ZONE.local(2026, 11, 20, 11)).attributes
      end)
      Service::ReservationSlackCanvas.send(:agenda_markdown, shop, date)
      report('reservation_canvas', size) { Service::ReservationSlackCanvas.send(:agenda_markdown, shop, date) }
    end
  end

  [1, 4].each do |channels|
    it "measures announcement reconciliation across #{channels} channels" do
      travel_to(ReservationService::ZONE.local(2026, 11, 20, 8)) do
        client = double('Slack benchmark client')
        allow(Service::SlackConnector).to receive(:message_destination_mode).and_return('production')
        allow(Service::SlackConnector).to receive(:resolved_channel_id) { |channel| channel }
        allow(Service::SlackConnector).to receive(:client).and_return(client)
        allow(Service::SlackConnector).to receive(:record_slack_message)
        allow(Service::SlackConnector).to receive(:slack_canvas_url) { |id| "https://example.com/#{id}" }
        allow(client).to receive(:chat_postMessage) { |**payload| { 'ts' => '123.456', 'channel' => payload[:channel] } }
        allow(client).to receive(:chat_update) { |**payload| { 'ts' => payload[:ts], 'channel' => payload[:channel] } }
        allow(Service::ReservationSlackCanvas).to receive(:ensure_today_for_announcement!) do |shop, **|
          Service::ReservationSlackCanvas.send(:agenda_markdown, shop, Time.current.in_time_zone(ReservationService::ZONE).to_date)
          shop.set(canvas_today: "F#{shop.id}")
          "F#{shop.id}"
        end
        member = create(:member, :current)
        channels.times do |number|
          shop = create(:shop, slack_channel: "CBENCH000#{number}")
          tool = create(:tool, shop: shop, users_channel: shop.slack_channel)
          Reservation.collection.insert_many(Array.new(10) do |row|
            Reservation.new(member: member, shop: shop, title: "Benchmark #{row}", reservation_scope: 'tools',
              tool_ids: [tool.id.to_s], start_at: ReservationService::ZONE.local(2026, 11, 20, 10),
              end_at: ReservationService::ZONE.local(2026, 11, 20, 11)).attributes
          end)
        end
        Service::ReservationSlackAnnouncements.sync!
        report('announcer_unchanged', channels) { Service::ReservationSlackAnnouncements.sync! }
        report('announcer_canvas_refresh', channels) do
          # This is setup, not a read; it forces the changed-content/canvas path.
          ReservationSlackAnnouncement.update_all(fingerprint: nil)
          Service::ReservationSlackAnnouncements.sync!
        end
      end
    end
  end
end
