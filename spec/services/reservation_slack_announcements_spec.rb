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

  it 'scopes a channel refresh to its live bindings and retained shops' do
    reservation = booking
    other_shop = create(:shop, name: 'Metalshop', slack_channel: 'COTHER0001')
    other_member = create(:member, :current)
    other_reservation = create(:reservation, shop: other_shop, member: other_member,
      start_at: reservation.start_at, end_at: reservation.end_at)

    snapshot = described_class::Snapshot.new(date, 'production', channel_id: tool_channel)
    expect(snapshot.channels.keys).to eq([tool_channel])
    expect(snapshot.member_names.keys).to eq([member.id.to_s])

    retained = described_class::Snapshot.new(date, 'production', channel_id: tool_channel,
      retained_shop_ids: [other_shop.id.to_s])
    expect(retained.data('COTHER0001')[:starting].map(&:id)).to eq([other_reservation.id])
  end

  it 'does not hydrate names while discovering destinations' do
    booking
    expect(ReservationDisplayQuery).not_to receive(:member_names)
    snapshot = described_class::Snapshot.new(date, 'production', load_member_names: false)
    expect(snapshot.channels.keys).to eq([tool_channel])
  end

  it 'does not treat an unrelated inactive unresolved binding as a delivery failure' do
    booking
    create(:shop, name: 'Unused shop', slack_channel: '#unused', slack_announce_empty_reservations: false)
    allow(Service::SlackChannelCache).to receive(:fetch).with('#unused').and_return(nil)
    expect(Service::SlackConnector).not_to receive(:resolved_channel_id).with('#unused')
    snapshot = described_class::Snapshot.new(date, 'production', channel_id: tool_channel)
    expect(snapshot.errors).to be_empty
    expect(snapshot.data(tool_channel)[:starting].length).to eq(1)
  end

  it 'uses cached alias bindings to scope without contacting unrelated Slack destinations' do
    booking
    other_shop = create(:shop, name: 'Metalshop', slack_channel: '#metalshop')
    create(:reservation, shop: other_shop, member: member, start_at: zone.local(2026, 11, 20, 12),
      end_at: zone.local(2026, 11, 20, 13))
    allow(Service::SlackChannelCache).to receive(:fetch).with('#metalshop').and_return(id: 'COTHER0001')
    expect(Service::SlackConnector).not_to receive(:resolved_channel_id).with('#metalshop')

    snapshot = described_class::Snapshot.new(date, 'production', channel_id: tool_channel)
    expect(snapshot.channels.keys).to eq([tool_channel])
  end

  it 'rechecks availability after publishing through the real canvas path' do
    shop.update!(reservable: false, slack_announce_empty_reservations: true)
    shop.set(canvas_today: 'FEXISTING')
    tool
    allow(Service::ReservationSlackCanvas).to receive(:ensure_today_for_announcement!).and_call_original
    allow(Service::SlackConnector).to receive(:set_canvas_channel_access)
    allow(Service::SlackConnector).to receive(:find_channel_id).and_return(shop_channel)
    allow(Service::SlackConnector).to receive(:replace_canvas) do |_id, markdown|
      expect(markdown).to include('Woodshop', 'No pending or approved reservations')
      tool.set(out_of_service: true)
    end

    sync
    expect(Service::SlackConnector).to have_received(:replace_canvas).once
    expect(posts).to be_empty
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
    expect(client).to have_received(:chat_delete).with(channel: tool_channel, ts: '100.1').once
    expect(updates).to be_empty
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

  it 'deletes the saved invitation when its last represented shop is deleted and does not repeat the delete' do
    shop.update!(slack_announce_empty_reservations: true)
    sync
    receipt = ReservationSlackAnnouncement.first
    expect do
      Shop.find(shop.id).destroy
    end.to have_enqueued_job(ReservationSlackAnnouncementJob).with(date.iso8601)

    sync
    expect(client).to have_received(:chat_delete).with(channel: shop_channel, ts: '100.1').once
    expect(receipt.reload.deleted_at).to be_present
    expect(receipt.ts).to eq('100.1')
    expect(receipt.shop_ids).to be_empty
    expect(receipt.canvas_ids).to be_empty
    expect(receipt.fingerprint).to be_nil
    sync
    expect(client).to have_received(:chat_delete).once
    expect(posts.size).to eq(1)
    expect(updates).to be_empty
  end

  it 'records an already missing orphaned invitation as deleted without creating a replacement' do
    shop.update!(slack_announce_empty_reservations: true)
    sync
    receipt = ReservationSlackAnnouncement.first
    Shop.find(shop.id).destroy
    allow(client).to receive(:chat_delete).and_raise(Slack::Web::Api::Errors::SlackError.new('message_not_found'))
    sync
    expect(receipt.reload.deleted_at).to be_present
    expect(posts.size).to eq(1)
    expect(updates).to be_empty
  end

  it 'retries an orphaned invitation deletion failure without silently marking it deleted' do
    shop.update!(slack_announce_empty_reservations: true)
    sync
    receipt = ReservationSlackAnnouncement.first
    Shop.find(shop.id).destroy
    allow(client).to receive(:chat_delete).and_raise(Slack::Web::Api::Errors::SlackError.new('cant_delete_message'))
    expect { sync }.to raise_error(described_class::DeliveryError, /cant_delete_message/)
    expect(receipt.reload.deleted_at).to be_nil
    expect(receipt.last_error).to include('cant_delete_message')
    expect(receipt.retry_at).to be_present
    allow(client).to receive(:chat_delete).and_return('ok' => true)
    travel_to(zone.local(2026, 11, 20, 8, 1)) { sync }
    expect(receipt.reload.deleted_at).to be_present
    expect(receipt.last_error).to be_nil
    expect(client).to have_received(:chat_delete).twice
    expect(posts.size).to eq(1)
  end

  it 'updates a shared-channel invitation to retain the other represented shop after one shop is deleted' do
    shop.update!(slack_announce_empty_reservations: true)
    other_shop = create(:shop, name: 'Metalshop', slack_channel: shop_channel, slack_announce_empty_reservations: true)
    sync
    receipt = ReservationSlackAnnouncement.first
    Shop.find(shop.id).destroy
    sync
    expect(client).not_to have_received(:chat_delete)
    expect(updates.first[:ts]).to eq('100.1')
    expect(text(updates.first)).to include('Metalshop', other_shop.id.to_s)
    expect(text(updates.first)).not_to include('Woodshop', shop.id.to_s)
    expect(receipt.reload.shop_ids).to eq([other_shop.id.to_s])
    expect(receipt.deleted_at).to be_nil
  end

  it 'deletes an existing invitation if its last shop disappears during canvas refresh' do
    shop.update!(slack_announce_empty_reservations: true)
    sync
    receipt = ReservationSlackAnnouncement.first
    shop.update!(name: 'Renamed shop')
    allow(Service::ReservationSlackCanvas).to receive(:ensure_today_for_announcement!) do |resource, **_options|
      Shop.find(resource.id).destroy
      "F#{resource.id}"
    end
    sync
    expect(client).to have_received(:chat_delete).with(channel: shop_channel, ts: '100.1').once
    expect(receipt.reload.deleted_at).to be_present
    expect(posts.size).to eq(1)
    expect(updates).to be_empty
  end

  it 'posts a fresh invitation if another shop later uses a channel whose invitation was deleted' do
    shop.update!(slack_announce_empty_reservations: true)
    sync
    receipt = ReservationSlackAnnouncement.first
    first_client_msg_id = receipt.client_msg_id
    Shop.find(shop.id).destroy
    sync
    replacement = create(:shop, name: 'Replacement shop', slack_channel: shop_channel, slack_announce_empty_reservations: true)
    sync
    expect(posts.size).to eq(2)
    expect(updates).to be_empty
    expect(text(posts.last)).to include('Replacement shop', replacement.id.to_s)
    expect(receipt.reload.ts).to eq('100.2')
    expect(receipt.deleted_at).to be_nil
    expect(receipt.shop_ids).to eq([replacement.id.to_s])
    expect(receipt.client_msg_id).not_to eq(first_client_msg_id)
    expect(posts.last[:client_msg_id]).to eq(receipt.client_msg_id)
  end

  it 'does not delete a message for an unsent receipt after its shop is removed' do
    ReservationSlackAnnouncement.create!(day: date.iso8601, mode: 'production', channel_id: shop_channel,
      shop_ids: [shop.id.to_s])
    Shop.find(shop.id).destroy
    sync
    expect(client).not_to have_received(:chat_delete)
    expect(posts).to be_empty
    expect(updates).to be_empty
  end

  describe 'tool routing changes' do
    before do
      shop.update!(reservable: false, slack_announce_empty_reservations: true)
    end

    it 'deletes the old invitation when the last tool serving its users channel is deleted' do
      tool
      sync
      receipt = ReservationSlackAnnouncement.first
      Tool.find(tool.id).destroy
      sync
      expect(client).to have_received(:chat_delete).with(channel: tool_channel, ts: '100.1').once
      expect(receipt.reload.deleted_at).to be_present
      expect(posts.size).to eq(1)
      expect(updates).to be_empty
    end

    it 'deletes a fallback-channel invitation when its only reservable tool is deleted' do
      tool.update!(users_channel: nil)
      sync
      Tool.find(tool.id).destroy
      sync
      expect(client).to have_received(:chat_delete).with(channel: shop_channel, ts: '100.1').once
      expect(posts.size).to eq(1)
      expect(updates).to be_empty
    end

    it 'deletes the old invitation when a tool moves to a shop with invitations off' do
      tool
      sync
      destination = create(:shop, name: 'Metalshop', slack_channel: 'COTHER0001', reservable: false)
      tool.update!(shop: destination)
      sync
      expect(client).to have_received(:chat_delete).with(channel: tool_channel, ts: '100.1').once
      expect(updates).to be_empty
      expect(posts.size).to eq(1)
    end

    it 'clears the old fallback channel and advertises a moved tool in its opted-in destination shop' do
      tool.update!(users_channel: nil)
      sync
      destination = create(:shop, name: 'Metalshop', slack_channel: 'COTHER0001', reservable: false,
        slack_announce_empty_reservations: true)
      tool.update!(shop: destination)
      sync
      expect(client).to have_received(:chat_delete).with(channel: shop_channel, ts: '100.1').once
      expect(posts.map { |payload| payload[:channel] }).to eq([shop_channel, 'COTHER0001'])
      expect(text(posts.last)).to include('Metalshop', destination.id.to_s, 'Bandsaw is wide open')
      expect(text(posts.last)).not_to include('Woodshop', shop.id.to_s)
    end

    it 'reuses the existing message with the new shop context when a moved tool keeps its users channel' do
      tool
      sync
      destination = create(:shop, name: 'Metalshop', slack_channel: 'COTHER0001', reservable: false,
        slack_announce_empty_reservations: true)
      tool.update!(shop: destination)
      sync
      expect(posts.size).to eq(1)
      expect(client).not_to have_received(:chat_delete)
      expect(updates.first[:ts]).to eq('100.1')
      expect(text(updates.first)).to include('Metalshop', destination.id.to_s)
      expect(text(updates.first)).not_to include('Woodshop', shop.id.to_s)
    end

    it 'deletes a retired users-channel invitation and posts in the new users channel' do
      tool
      sync
      tool.update!(users_channel: 'CTOOL00002')
      sync
      expect(client).to have_received(:chat_delete).with(channel: tool_channel, ts: '100.1').once
      expect(posts.map { |payload| payload[:channel] }).to eq([tool_channel, 'CTOOL00002'])
      expect(updates).to be_empty
      expect(text(posts.last)).to include('Bandsaw is wide open')
    end

    it 'replaces a cleared users channel with the shop fallback without leaving the old post behind' do
      tool
      sync
      tool.update!(users_channel: nil)
      sync
      expect(client).to have_received(:chat_delete).with(channel: tool_channel, ts: '100.1').once
      expect(posts.map { |payload| payload[:channel] }).to eq([tool_channel, shop_channel])
      expect(updates).to be_empty
    end

    it 'removes the old shop fallback when a tool gains a dedicated users channel' do
      tool.update!(users_channel: nil)
      sync
      tool.update!(users_channel: tool_channel)
      sync
      expect(client).to have_received(:chat_delete).with(channel: shop_channel, ts: '100.1').once
      expect(posts.map { |payload| payload[:channel] }).to eq([shop_channel, tool_channel])
      expect(updates).to be_empty
    end

    it 'keeps other tools in a shared channel when a tool is deleted' do
      tool
      create(:tool, shop: shop, name: 'Lathe', users_channel: tool_channel)
      sync
      Tool.find(tool.id).destroy
      sync
      expect(client).not_to have_received(:chat_delete)
      expect(updates.first[:ts]).to eq('100.1')
      expect(text(updates.first)).to include('Lathe is wide open')
      expect(text(updates.first)).not_to include('Bandsaw')
    end

    it 'keeps other tools in the old users channel when a tool is reassigned' do
      tool
      create(:tool, shop: shop, name: 'Lathe', users_channel: tool_channel)
      sync
      tool.update!(users_channel: 'CTOOL00002')
      sync
      expect(client).not_to have_received(:chat_delete)
      old_update = updates.find { |payload| payload[:channel] == tool_channel }
      expect(old_update[:ts]).to eq('100.1')
      expect(text(old_update)).to include('Lathe is wide open')
      expect(text(old_update)).not_to include('Bandsaw')
      expect(text(posts.last)).to include('Bandsaw is wide open')
    end

    it 'preserves the saved message when a changed channel cannot be resolved' do
      tool
      sync
      receipt = ReservationSlackAnnouncement.first
      fingerprint = receipt.fingerprint
      shop.update!(slack_announce_empty_reservations: false)
      tool.update!(users_channel: '#missing')
      expect { sync }.to raise_error(described_class::DeliveryError, /Channel resolution incomplete/)
      expect(client).not_to have_received(:chat_delete)
      expect(updates).to be_empty
      expect(receipt.reload.fingerprint).to eq(fingerprint)
      expect(receipt.deleted_at).to be_nil
    end

    it 'retains a confirmed users-channel binding when an unrelated shop channel cannot resolve' do
      tool
      sync
      shop.update!(slack_announce_empty_reservations: false, slack_channel: '#missing')
      sync
      expect(client).not_to have_received(:chat_delete)
      expect(updates.first[:ts]).to eq('100.1')
      expect(text(updates.first)).to include('No reservations to announce')
      expect(text(updates.first)).not_to include('wide open')
    end

    it 'removes a retired destination if the users channel changes during canvas refresh' do
      tool
      sync
      tool.update!(name: 'Renamed bandsaw')
      allow(Service::ReservationSlackCanvas).to receive(:ensure_today_for_announcement!) do |resource, **_options|
        resource.set(canvas_today: "F#{resource.id}")
        tool.update!(users_channel: 'CTOOL00002')
        "F#{resource.id}"
      end
      sync
      expect(client).to have_received(:chat_delete).with(channel: tool_channel, ts: '100.1').once
      expect(updates).to be_empty
      sync
      expect(posts.map { |payload| payload[:channel] }).to eq([tool_channel, 'CTOOL00002'])
    end

    it 'does not send a historical booking in the old shop to a moved tool\'s new users channel' do
      shop.update!(slack_announce_empty_reservations: false)
      booking(start_at: zone.local(2026, 11, 20, 6), end_at: zone.local(2026, 11, 20, 7))
      sync
      destination = create(:shop, name: 'Metalshop', slack_channel: 'COTHER0001', reservable: false)
      tool.update!(shop: destination, users_channel: 'CTOOL00002')
      sync
      expect(posts.map { |payload| payload[:channel] }).to eq([tool_channel, shop_channel])
      expect(text(posts.last)).to include('Woodshop', 'Project time')
      expect(client).to have_received(:chat_delete).with(channel: tool_channel, ts: '100.1').once
    end

    it 'keeps a deleted tool\'s earlier booking in its shop without retaining the retired users post' do
      shop.update!(slack_announce_empty_reservations: false)
      booking(start_at: zone.local(2026, 11, 20, 6), end_at: zone.local(2026, 11, 20, 7))
      sync
      Tool.find(tool.id).destroy
      sync
      expect(posts.map { |payload| payload[:channel] }).to eq([tool_channel, shop_channel])
      expect(text(posts.last)).to include('Woodshop', 'Project time')
      expect(client).to have_received(:chat_delete).with(channel: tool_channel, ts: '100.1').once
    end
  end
end
