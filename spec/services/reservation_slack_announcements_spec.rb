require 'rails_helper'

RSpec.describe Service::ReservationSlackAnnouncements do
  let(:zone) { ReservationService::ZONE }
  let(:date) { Date.new(2026, 11, 20) }
  let(:shop_channel) { 'CSHOP00001' }
  let(:tool_channel) { 'CTOOL00001' }
  let(:shop) { create(:shop, name: 'Woodshop', slack_channel: shop_channel) }
  let(:tool) { create(:tool, shop: shop, name: 'Bandsaw', users_channel: tool_channel) }
  let(:member) { create(:member, :current) }
  let(:client) { double('Slack client') }
  let(:posts) { [] }
  let(:updates) { [] }

  around do |example|
    travel_to(zone.local(2026, 11, 20, 8))
    example.run
  ensure
    travel_back
  end

  before do
    ActiveJob::Base.queue_adapter = :test
    allow(Service::MemberProvisioning).to receive(:invite_slack)
    allow(Service::SlackConnector).to receive(:message_destination_mode).and_return('production')
    allow(Service::SlackConnector).to receive(:resolved_channel_id) { |channel| channel }
    allow(Service::SlackConnector).to receive(:client).and_return(client)
    allow(Service::SlackConnector).to receive(:record_slack_message)
    allow(Service::SlackConnector).to receive(:slack_canvas_url) { |id| "https://makerspace.slack.com/docs/TTEST00001/#{id}" }
    allow(Service::ReservationSlackCanvas).to receive(:ensure_today_for_announcement!) do |resource, **options|
      field = options[:mode] == 'production' ? :canvas_today : :announcement_test_canvas_today
      resource.set(field => "F#{resource.id}")
      "F#{resource.id}"
    end
    allow(client).to receive(:chat_postMessage) do |**payload|
      posts << payload
      { 'ts' => "100.#{posts.length}", 'channel' => payload[:channel] }
    end
    allow(client).to receive(:chat_update) do |**payload|
      updates << payload
      { 'ts' => payload[:ts], 'channel' => payload[:channel] }
    end
    allow(client).to receive(:chat_delete).and_return('ok' => true)
  end

  def booking(scope: 'tools', tools: [tool], **attributes)
    create(:reservation, { shop: shop, member: member, reservation_scope: scope,
      tool_ids: scope == 'shop' ? [] : tools.map { |resource| resource.id.to_s },
      start_at: zone.local(2026, 11, 20, 10), end_at: zone.local(2026, 11, 20, 11) }.merge(attributes))
  end

  def sync
    described_class.sync!(date: date.iso8601)
  end

  def text(payload)
    JSON.generate(payload[:blocks])
  end

  it 'posts a dated tool summary with its status, live canvas and reservation button, retaining string ts' do
    booking(title: 'Make a cabinet', status: 'pending')
    sync
    expect(posts.size).to eq(1)
    expect(posts.first[:channel]).to eq(tool_channel)
    expect(text(posts.first)).to include('Friday, November 20, 2026', 'Pending', 'Make a cabinet',
      'Bandsaw', 'Live today agenda', 'reservation_open', shop.id.to_s)
    receipt = ReservationSlackAnnouncement.first
    expect(receipt.ts).to eq('100.1')
    expect(receipt.shop_ids).to eq([shop.id.to_s])
    expect(receipt.canvas_ids[shop.id.to_s]).to eq("F#{shop.id}")
    expect(receipt.sending_at).to be_nil
  end

  it 'fans whole-shop reservations out to shop and all users channels, deduplicating aliases and tools' do
    tool
    create(:tool, shop: shop, users_channel: tool_channel)
    create(:tool, shop: shop, users_channel: 'CTOOL00002')
    booking(scope: 'shop')
    sync
    expect(posts.map { |payload| payload[:channel] }).to contain_exactly(shop_channel, tool_channel, 'CTOOL00002')
    expect(posts.map { |payload| text(payload).scan('Project time').size }).to eq([1, 1, 1])
  end

  it 'uses the shop channel for tools without a users channel and posts a multi-tool booking once' do
    tool.update!(users_channel: nil)
    second = create(:tool, shop: shop, users_channel: shop_channel)
    booking(tools: [tool, second])
    sync
    expect(posts.map { |payload| payload[:channel] }).to eq([shop_channel])
    expect(text(posts.first).scan('Project time').size).to eq(1)
  end

  it 'includes all blocking statuses but excludes cancelled, denied, yesterday and tomorrow starts' do
    %w[pending unpaid approved cancelled denied].each { |status| booking(title: "Booking #{status}", status: status) }
    booking(title: 'Yesterday', start_at: zone.local(2026, 11, 19, 23), end_at: zone.local(2026, 11, 20, 9))
    booking(title: 'Tomorrow', start_at: zone.local(2026, 11, 21), end_at: zone.local(2026, 11, 21, 1))
    sync
    expect(text(posts.first)).to include('Booking pending', 'Booking unpaid', 'Booking approved')
    expect(text(posts.first)).not_to include('Booking cancelled', 'Booking denied', 'Yesterday', 'Tomorrow')
  end

  it 'keeps bookings that began earlier today including ended and full-day bookings' do
    booking(title: 'Early', start_at: zone.local(2026, 11, 20), end_at: zone.local(2026, 11, 20, 1))
    booking(title: 'All day', full_day: true, start_at: zone.local(2026, 11, 20), end_at: zone.local(2026, 11, 21))
    sync
    expect(text(posts.first)).to include('Early', 'All day', 'Full day')
  end

  it 'suppresses pre-7-AM and stale jobs and opens at exactly 7 AM local time' do
    booking
    travel_to(zone.local(2026, 11, 20, 6, 59)) { expect(sync).to eq(:skipped) }
    expect(described_class.sync!(date: '2026-11-19')).to eq(:skipped)
    expect(posts).to be_empty
    travel_to(zone.local(2026, 11, 20, 7)) { sync }
    expect(posts.size).to eq(1)
  end

  it 'uses New York cutovers and day boundaries on both DST transition dates' do
    [[2026, 3, 8], [2026, 11, 1]].each do |year, month, day|
      local_date = Date.new(year, month, day)
      travel_to(zone.local(year, month, day, 7)) do
        create(:reservation, shop: shop, member: member, start_at: zone.local(year, month, day),
          end_at: zone.local(year, month, day, 1))
        described_class.sync!(date: local_date.iso8601)
        expect(ReservationSlackAnnouncement.where(day: local_date.iso8601).count).to eq(1)
      end
    end
  end

  it 'edits the saved ts when bookings change and leaves unchanged payloads alone' do
    reservation = booking
    sync
    sync
    expect(posts.size).to eq(1)
    expect(updates).to be_empty
    expect(Service::ReservationSlackCanvas).to have_received(:ensure_today_for_announcement!).once
    reservation.update!(title: 'Changed title')
    sync
    expect(updates.size).to eq(1)
    expect(updates.first[:ts]).to eq('100.1')
    expect(updates.first[:blocks]).to be_present
    expect(text(updates.first)).to include('Changed title', 'reservation_open')
  end

  it 'clears old destinations after a booking moves to a different day, retaining links, button and ts' do
    reservation = booking
    sync
    reservation.update!(start_at: zone.local(2026, 11, 21, 10), end_at: zone.local(2026, 11, 21, 11))
    sync
    expect(posts.size).to eq(1)
    expect(updates.first[:ts]).to eq('100.1')
    expect(text(updates.first)).to include('No reservations to announce for Friday, November 20, 2026', 'reservation_open', 'Live today agenda')
  end

  it 'removes a booking from its old users channel and posts it in the changed channel' do
    booking
    sync
    tool.update!(users_channel: 'CTOOL00002')
    sync
    expect(posts.map { |payload| payload[:channel] }).to eq([tool_channel, 'CTOOL00002'])
    expect(updates.first[:channel]).to eq(tool_channel)
    expect(text(updates.first)).not_to include('Project time')
  end

  it 'defaults to no empty posts and advertises opted-in empty channels only' do
    tool
    sync
    expect(posts).to be_empty
    shop.update!(slack_announce_empty_reservations: true)
    sync
    expect(posts.map { |payload| payload[:channel] }).to contain_exactly(shop_channel, tool_channel)
    expect(text(posts.find { |payload| payload[:channel] == shop_channel })).to include('Shop is wide open, book your time now!')
    expect(text(posts.find { |payload| payload[:channel] == tool_channel })).to include('Bandsaw is wide open')
  end

  it 'suppresses invitations in booked shared channels and for a shop containing any booking' do
    shop.update!(slack_announce_empty_reservations: true)
    create(:tool, shop: shop, users_channel: tool_channel)
    booking
    sync
    expect(posts.size).to eq(1)
    expect(text(posts.first)).not_to include('wide open')
  end

  it 'does not advertise carryovers, whole-shop blocking bookings, blackouts or outages as empty' do
    shop.update!(slack_announce_empty_reservations: true)
    tool
    reservation = booking(scope: 'shop', start_at: zone.local(2026, 11, 19, 23), end_at: zone.local(2026, 11, 20, 12))
    sync
    expect(posts).to be_empty
    reservation.update!(status: 'cancelled')
    blackout = create(:reservation_blackout, shop: shop, recurrence: 'daily', weekday: nil)
    sync
    expect(posts).to be_empty
    blackout.destroy
    shop.reload.update!(out_of_service: true, out_of_service_note: 'Maintenance')
    sync
    expect(posts).to be_empty
  end

  it 'replaces empty invitations in place when a booking appears or the setting is switched off' do
    shop.update!(slack_announce_empty_reservations: true)
    sync
    reservation = booking(scope: 'shop')
    sync
    expect(text(updates.last)).to include('Project time')
    expect(text(updates.last)).not_to include('wide open')
    reservation.update!(status: 'cancelled')
    shop.update!(slack_announce_empty_reservations: false)
    sync
    expect(text(updates.last)).to include('No reservations to announce')
    expect(text(updates.last)).not_to include('wide open')
  end

  it 'reposts only when Slack confirms message_not_found and saves the replacement timestamp' do
    reservation = booking
    sync
    reservation.update!(title: 'Changed')
    allow(client).to receive(:chat_update).and_raise(Slack::Web::Api::Errors::SlackError.new('message_not_found'))
    sync
    expect(posts.size).to eq(2)
    expect(ReservationSlackAnnouncement.first.ts).to eq('100.2')
  end

  it 'does not repost on update permission errors and records retry state' do
    reservation = booking
    sync
    reservation.update!(title: 'Changed')
    allow(client).to receive(:chat_update).and_raise(Slack::Web::Api::Errors::SlackError.new('cant_update_message'))
    expect { sync }.to raise_error(described_class::DeliveryError)
    expect(posts.size).to eq(1)
    expect(ReservationSlackAnnouncement.first.last_error).to include('cant_update_message')
    expect(ReservationSlackAnnouncement.first.ts).to eq('100.1')
  end

  it 'does not blindly repost after a timeout during initial delivery' do
    booking
    allow(client).to receive(:chat_postMessage).and_raise(Timeout::Error)
    expect { sync }.to raise_error(described_class::DeliveryError)
    expect(ReservationSlackAnnouncement.first.sending_at).to be_present
    expect { sync }.to raise_error(described_class::DeliveryError, /AMBIGUOUS_SEND/)
    expect(client).to have_received(:chat_postMessage).once
  end

  it 'preserves old posts when a configured channel cannot be resolved and continues other channels' do
    reservation = booking
    sync
    tool.update!(users_channel: '#missing')
    other_shop = create(:shop, slack_channel: 'COTHER0001')
    create(:reservation, shop: other_shop, member: member, start_at: zone.local(2026, 11, 20, 10), end_at: zone.local(2026, 11, 20, 11))
    expect { sync }.to raise_error(described_class::DeliveryError, /resolved|resolution/)
    expect(updates).to be_empty
    expect(posts.map { |payload| payload[:channel] }).to include('COTHER0001')
    expect(ReservationSlackAnnouncement.find_by(channel_id: tool_channel).fingerprint).to be_present
  end

  it 'never publishes before a valid fresh canvas and URL are available' do
    booking
    allow(Service::SlackConnector).to receive(:slack_canvas_url).and_return(nil)
    expect { sync }.to raise_error(described_class::DeliveryError, /canvas URL unavailable/)
    expect(posts).to be_empty
  end

  it 'isolates redirected test deliveries and collapses all destinations into the effective test channel' do
    booking(scope: 'shop')
    tool
    sync
    allow(Service::SlackConnector).to receive(:message_destination_mode).and_return('test')
    allow(Service::SlackConnector).to receive(:resolved_channel_id).and_return('CTEST00001')
    sync
    expect(posts.map { |payload| payload[:channel] }).to contain_exactly(shop_channel, tool_channel, 'CTEST00001')
    expect(updates).to be_empty
    expect(ReservationSlackAnnouncement.where(mode: 'test').count).to eq(1)
    expect(Service::ReservationSlackCanvas).to have_received(:ensure_today_for_announcement!).with(anything,
      channel_id: 'CTEST00001', date: date, mode: 'test')
  end

  it 'escapes mention markup and bounds oversized summaries with explicit overflow links' do
    42.times { |index| booking(title: "Booking #{index} <@everyone>") }
    sync
    expect(posts.first[:blocks].length).to be <= 50
    expect(text(posts.first)).to include('&lt;@everyone&gt;', 'omitted', 'All reservations')
    expect(text(posts.first)).not_to include('Booking 0 <@everyone>')
  end

  it 'does not let a failed unsent receipt create a neutral empty post after cancellation' do
    reservation = booking
    allow(Service::ReservationSlackCanvas).to receive(:ensure_today_for_announcement!).and_raise('Canvas failed')
    expect { sync }.to raise_error(described_class::DeliveryError)
    reservation.update!(status: 'cancelled')
    travel_to(zone.local(2026, 11, 20, 9)) { sync }
    expect(posts).to be_empty
  end

  it 'refreshes the message when another canvas sync replaces its cached canvas ID' do
    booking
    sync
    shop.reload.set(canvas_today: 'FREPLACEMENT')
    allow(Service::ReservationSlackCanvas).to receive(:ensure_today_for_announcement!).and_return('FREPLACEMENT')
    sync
    expect(text(updates.first)).to include('FREPLACEMENT')
  end

  it 'honors Retry-After without duplicating a rejected send or advancing attempts before its due time' do
    booking
    rate_limit = Class.new(StandardError) { def retry_after = 60 }.new('rate limited')
    allow(client).to receive(:chat_postMessage).and_raise(rate_limit)
    expect { sync }.to raise_error(described_class::DeliveryError)
    receipt = ReservationSlackAnnouncement.first
    expect(receipt.sending_at).to be_nil
    expect(receipt.retry_at).to eq(Time.current + 60)
    expect { sync }.to raise_error(described_class::DeliveryError, /deferred/)
    expect(receipt.reload.attempts).to eq(1)
    expect(client).to have_received(:chat_postMessage).once
    allow(client).to receive(:chat_postMessage) { |**payload| { 'ts' => '200.1', 'channel' => payload[:channel] } }
    travel_to(zone.local(2026, 11, 20, 8, 1)) { sync }
    expect(receipt.reload.ts).to eq('200.1')
  end

  it 'permits only one initial post when two workers reconcile the same channel concurrently' do
    booking
    started = Queue.new
    release = Queue.new
    allow(client).to receive(:chat_postMessage) do |**payload|
      posts << payload
      started << true
      release.pop
      { 'ts' => '300.1', 'channel' => payload[:channel] }
    end
    worker = Thread.new { sync }
    Timeout.timeout(10) { started.pop }
    sync
    expect(posts.size).to eq(1)
    release << true
    expect(worker.join(10)).to eq(worker)
    worker.value
    expect(ReservationSlackAnnouncement.count).to eq(1)
  ensure
    release << true if release && worker&.alive?
    worker&.join(10)
  end

  it 'invalidates the fingerprint after losing the lease following a successful send' do
    booking
    allow(ReservationAnnouncementLease).to receive(:with) do |_identity, &block|
      calls = 0
      block.call(-> { calls += 1; raise ReservationAnnouncementLease::Busy if calls == 5 })
    end
    sync
    receipt = ReservationSlackAnnouncement.first
    expect(receipt.ts).to eq('100.1')
    expect(receipt.fingerprint).to be_nil
    allow(ReservationAnnouncementLease).to receive(:with) { |_identity, &block| block.call(-> {}) }
    sync
    expect(posts.size).to eq(1)
    expect(updates.size).to eq(1)
    expect(receipt.reload.fingerprint).to be_present
  end

  it "deletes yesterday's empty message by its saved ts before today's initial post" do
    booking
    previous = ReservationSlackAnnouncement.create!(day: '2026-11-19', mode: 'production',
      channel_id: tool_channel, ts: 'yesterday.empty', empty_agenda: true)
    expect(client).to receive(:chat_delete).with(channel: tool_channel, ts: 'yesterday.empty').ordered
    expect(client).to receive(:chat_postMessage).ordered.and_return('ts' => 'today.1', 'channel' => tool_channel)
    sync
    expect(previous.reload.deleted_at).to be_present
    expect(previous.ts).to eq('yesterday.empty')
    expect(ReservationSlackAnnouncement.find_by(day: date.iso8601).ts).to eq('today.1')
  end

  it "does not clean yesterday's empty message when no new message is eligible today" do
    previous = ReservationSlackAnnouncement.create!(day: '2026-11-19', mode: 'production',
      channel_id: tool_channel, ts: 'yesterday.empty', empty_agenda: true)
    sync
    expect(posts).to be_empty
    expect(client).not_to have_received(:chat_delete)
    expect(previous.reload.deleted_at).to be_nil
  end

  it "does not delete yesterday's nonempty post, a different channel, or a different mode" do
    booking
    ReservationSlackAnnouncement.create!(day: '2026-11-19', mode: 'production', channel_id: tool_channel,
      ts: 'booked', empty_agenda: false)
    ReservationSlackAnnouncement.create!(day: '2026-11-19', mode: 'test', channel_id: tool_channel,
      ts: 'test-empty', empty_agenda: true)
    ReservationSlackAnnouncement.create!(day: '2026-11-19', mode: 'production', channel_id: shop_channel,
      ts: 'other-channel-empty', empty_agenda: true)
    sync
    expect(client).not_to have_received(:chat_delete)
  end

  it "continues today's posting if yesterday's empty message cannot be deleted" do
    booking
    previous = ReservationSlackAnnouncement.create!(day: '2026-11-19', mode: 'production',
      channel_id: tool_channel, ts: 'yesterday.empty', empty_agenda: true)
    allow(client).to receive(:chat_delete).and_raise(Slack::Web::Api::Errors::SlackError.new('cant_delete_message'))
    sync
    expect(posts.size).to eq(1)
    expect(previous.reload.deleted_at).to be_nil
  end

  it "treats an already missing empty post as cleaned and does not repeat deletion during today's edits" do
    reservation = booking
    previous = ReservationSlackAnnouncement.create!(day: '2026-11-19', mode: 'production',
      channel_id: tool_channel, ts: 'yesterday.empty', empty_agenda: true)
    allow(client).to receive(:chat_delete).and_raise(Slack::Web::Api::Errors::SlackError.new('message_not_found'))
    sync
    reservation.update!(title: 'Changed')
    sync
    expect(previous.reload.deleted_at).to be_present
    expect(client).to have_received(:chat_delete).once
  end

  it 'tracks the last successfully delivered empty state when an invitation changes to a booking' do
    shop.update!(slack_announce_empty_reservations: true)
    sync
    receipt = ReservationSlackAnnouncement.first
    expect(receipt.empty_agenda).to be(true)
    booking(scope: 'shop')
    sync
    expect(receipt.reload.empty_agenda).to be(false)
  end

  %i[disabled out_of_service].each do |field|
    it "does not create a tool invitation when #{field} is already set" do
      shop.update!(reservable: false, slack_announce_empty_reservations: true)
      tool.update!(field => true)
      sync
      expect(posts).to be_empty
    end

    it "removes an existing tool invitation when #{field} changes" do
      shop.update!(reservable: false, slack_announce_empty_reservations: true)
      tool
      sync
      expect(text(posts.first)).to include('Bandsaw is wide open')
      tool.update!(field => true)
      sync
      expect(updates.first[:ts]).to eq('100.1')
      expect(text(updates.first)).not_to include('wide open', 'book your time now')
    end
  end

  it 'rechecks tool availability after slow canvas work and suppresses a newly stale invitation' do
    shop.update!(reservable: false, slack_announce_empty_reservations: true)
    tool
    allow(Service::ReservationSlackCanvas).to receive(:ensure_today_for_announcement!) do |resource, **_options|
      resource.set(canvas_today: 'FCANVAS')
      tool.set(out_of_service: true)
      'FCANVAS'
    end
    sync
    expect(posts).to be_empty
  end

  it 'continues healthy empty invitations when an unrelated shop channel cannot be resolved' do
    shop.update!(slack_announce_empty_reservations: true)
    other_shop = create(:shop, slack_channel: '#missing')
    create(:reservation, shop: other_shop, member: member, start_at: zone.local(2026, 11, 20, 10),
      end_at: zone.local(2026, 11, 20, 11))
    expect { sync }.to raise_error(described_class::DeliveryError)
    expect(posts.size).to eq(1)
    expect(posts.first[:channel]).to eq(shop_channel)
    expect(text(posts.first)).to include('Shop is wide open')
    expect { sync }.to raise_error(described_class::DeliveryError)
    expect(updates).to be_empty
  end

  it 'still delivers a whole-shop booking to valid fanout destinations when another users channel is broken' do
    tool
    create(:tool, shop: shop, users_channel: '#missing')
    booking(scope: 'shop')
    expect { sync }.to raise_error(described_class::DeliveryError)
    expect(posts.map { |payload| payload[:channel] }).to contain_exactly(shop_channel, tool_channel)
    expect(posts.all? { |payload| text(payload).include?('Project time') }).to be(true)
  end

  it 'preserves existing rows when a failed alias hides a booking while another booking still resolves' do
    second = create(:tool, shop: shop, users_channel: '#other-alias')
    allow(Service::SlackConnector).to receive(:resolved_channel_id).with('#other-alias').and_return(tool_channel)
    booking(scope: 'shop', title: 'Whole shop')
    booking(tools: [second], title: 'Tool-only booking')
    sync
    allow(Service::SlackConnector).to receive(:resolved_channel_id).with('#other-alias').and_return('#other-alias')
    expect { sync }.to raise_error(described_class::DeliveryError)
    expect(updates).to be_empty
  end

  it 'uses existing fee reconciliation to cancel overdue unpaid bookings that have already begun' do
    reservation = booking(status: 'unpaid', start_at: zone.local(2026, 11, 20, 6),
      end_at: zone.local(2026, 11, 20, 10))
    invoice = Invoice.create!(member: member, resource_id: member.id.to_s, resource_class: 'fee',
      amount: 10, due_date: zone.local(2026, 11, 20, 2), reservation_id: reservation.id.to_s)
    reservation.set(invoice: invoice.id.to_s)
    sync
    expect(reservation.reload.status).to eq('cancelled')
    expect(posts).to be_empty
  end

  it 'does not repeat fee reconciliation notifications for unpaid bookings before their start' do
    booking(status: 'unpaid')
    expect(ReservationFeeService).not_to receive(:reconcile!)
    sync
    expect(text(posts.first)).to include('Unpaid')
  end
end
