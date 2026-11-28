require 'rails_helper'

RSpec.describe 'Grouped Resource Managers checkout reminders' do
  let(:day) { Time.zone.local(2026, 10, 1, 9) }
  let(:shop) { create(:shop, name: 'Woodworking') }
  let(:member) { create(:member, :current, firstname: 'Pat', lastname: 'Member') }
  let(:slack) { Service::SlackConnector }
  let(:posts) { [] }
  let(:edits) { [] }

  before do
    allow(slack).to receive(:resource_managers_channel).and_return('resource_managers')
    allow(slack).to receive(:send_slack_message) do |text, _channel, client_msg_id:|
      posts << [text, client_msg_id]
      { 'ts' => "#{posts.size}.123", 'channel' => 'CRM' }
    end
    allow(slack).to receive(:update_slack_message) { |channel, ts, text, **| edits << [channel, ts, text] }
    allow(slack).to receive(:resolved_channel_id).and_return('CRM')
    allow(slack).to receive(:find_post_receipt).and_return(nil)
    allow(Service::ErrorReporter).to receive(:notify)
  end

  def request(name, who: member, where: shop, at: day)
    ToolCheckoutRequest.create!(member: who, tool: create(:tool, name: name, shop: where), request_date: at)
  end

  def scan(now = day + 5.days)
    CheckoutRequestReminder.deliver_due!(ToolCheckoutRequest.where(status: 'open'), now: now)
  end

  def shared_text(tools)
    "*Pat Member* requested checkout on *Woodworking* tools #{tools} on 2026-10-01 and is still waiting. " \
      "If this was already done in person, please record the outstanding checkouts."
  end

  it 'sorts dates before sending, merges mixed times and tool groups, and separates identities and deadlines' do
    drill = request('drill Press', at: day + 8.hours)
    band = request('Bandsaw')
    group = ToolGroup.create!(name: 'Lathes', shop: shop, included_tool_ids: [band.tool_id.to_s])
    lathes = ToolCheckoutRequest.create!(member: member, tool_group: group, request_date: day + 2.hours)
    other_member = request('Jointer', who: create(:member, :current, firstname: 'Pat', lastname: 'Member'))
    other_shop = request('Saw', where: create(:shop, name: 'Other Shop'))
    older = request('Orbital Sander', at: day - 1.day)
    final = request('Planer')
    final.set(reminders: { '1' => { 'status' => 'sent' }, '2' => { 'status' => 'sent' } })
    allow_any_instance_of(Shop).to receive(:name).and_return('Woodworking')

    2.times { scan(day + 15.days) }
    expect(posts.size).to eq(5)
    expect(posts.first.first).to include('Orbital Sander', '2026-09-30')
    receipts = [drill, band, lathes].map { |r| r.reload.reminders.fetch('3') }
    expect(receipts.uniq.size).to eq(1)
    expect(receipts.first).to include('channel' => 'CRM', 'status' => 'sent', 'grouped' => true)
    expect(posts).to include([shared_text('*Bandsaw*, *drill Press*, *Lathes (tool group)*'), receipts.first['delivery_id']])
    expect([older, other_member, other_shop, final].map { |r| r.reload.reminders.fetch('3')['ts'] }.uniq.size).to eq(4)
    expect(posts.count { |text, _| text.include?('last reminder') }).to eq(1)
    expect(posts.map(&:first).find { |text| text.include?('Planer') }).to include('declined on 2026-10-21')
    expect(CheckoutReminderDelivery.count).to eq(0)
  end

  it 'keeps a posted warning deadline through partial resolution and closes the exact post on mixed outcomes' do
    band = request('Bandsaw')
    drill = request('Drill Press')
    [5, 10, 15].each { |n| scan(day + n.days) }
    expect(posts.size).to eq(3)
    expect(band.reload.reminders.size).to eq(3)
    expect(drill.reload.reminders.size).to eq(3)
    late = request('Jointer')
    band.update!(status: 'closed')
    CheckoutRequestReminder.finalize!(band, now: day + 16.days)
    expect(edits.map(&:second)).to eq(%w[1.123 2.123 3.123])
    expect(edits.last.last).to include('*Drill Press*', 'declined on 2026-10-21')
    expect(edits.flat_map(&:last).join).not_to include('Bandsaw', late.target.name)
    expect(CheckoutRequestReminder.time_out_due!(drill, now: day + 19.days)).to be(false)
    expect(CheckoutRequestReminder.time_out_due!(drill, now: day + 20.days)).to be(true)
    CheckoutRequestReminder.finalize!(drill)
    expect(edits.last(3).map(&:last).uniq).to eq(['No checkout requests from *Pat Member* for *Woodworking* on 2026-10-01 are still waiting.'])
    expect(band.reload.reminder_open).to be(false)
    expect(drill.reload.reminder_open).to be(false)
  end

  it 'reuses the original delivery ID after a failed post and rechecks closed requests before retrying' do
    band = request('Bandsaw')
    drill = request('Drill Press')
    allow(slack).to receive(:send_slack_message).and_raise(IOError, 'connection lost')
    scan
    failed_id = CheckoutReminderDelivery.first.id
    expect([band, drill].map { |r| r.reload.reminders.dig('1', 'status') }).to eq(%w[failed failed])
    drill.update!(status: 'deleted')
    allow(slack).to receive(:send_slack_message).and_return({ 'ts' => '10.03', 'channel' => 'CRM' })
    scan
    expect(slack).to have_received(:send_slack_message).with(include('Bandsaw'), 'resource_managers', client_msg_id: failed_id).twice
    expect(slack).to have_received(:send_slack_message).with(include('*Bandsaw* (Woodworking)'), 'resource_managers', client_msg_id: failed_id).once
    expect(drill.reload.reminders.dig('1', 'status')).to eq('failed')
    expect(band.reload.reminders.dig('1', 'ts')).to eq('10.03')
  end

  it 'recovers an accepted post even after all requests close, without sending again' do
    band = request('Bandsaw')
    drill = request('Drill Press')
    allow(slack).to receive(:send_slack_message).and_raise(IOError, 'response lost')
    scan
    uuid = CheckoutReminderDelivery.first.id
    [band, drill].each { |r| r.update!(status: 'deleted') }
    allow(slack).to receive(:find_post_receipt).with(channel: 'CRM', oldest: anything, client_msg_id: uuid)
      .and_return({ 'channel' => 'CRM', 'ts' => '123.45' })
    scan(day + 6.days)
    expect(slack).to have_received(:send_slack_message).once
    expect([band, drill].map { |r| r.reload.reminders.dig('1', 'ts') }).to eq(%w[123.45 123.45])
    allow(slack).to receive(:update_slack_message).and_raise(IOError)
    expect { CheckoutRequestReminder.finalize!(band) }.to raise_error(IOError)
    expect(band.reload.reminder_open).to be(true)
    allow(slack).to receive(:update_slack_message)
    CheckoutRequestReminder.finalize!(band)
    expect(band.reload.reminder_open).to be(false)
    expect(slack).to have_received(:update_slack_message).with('CRM', '123.45', include('No checkout requests'), resolved_channel: true).twice
  end

  it 'serializes overlapping scans and edits and retries the losing edit from current state' do
    band = request('Bandsaw')
    drill = request('Drill Press')
    # Start another scan while the first worker is inside the Slack call.
    allow(slack).to receive(:send_slack_message) do
      Thread.new { scan }.value
      { 'ts' => '123.45', 'channel' => 'CRM' }
    end
    scan
    expect(slack).to have_received(:send_slack_message).once
    band.update!(status: 'closed')
    allow(slack).to receive(:update_slack_message) do |_, _, text, **|
      edits << text
      if edits.one?
        drill.update!(status: 'deleted')
        Thread.new { CheckoutRequestReminder.finalize!(drill) }.value
      end
    end
    CheckoutRequestReminder.finalize!(band)
    expect(drill.reload.reminder_open).to be(true)
    CheckoutRequestReminderJob.perform_now
    expect(edits).to eq([shared_text('*Drill Press*'), 'No checkout requests from *Pat Member* for *Woodworking* on 2026-10-01 are still waiting.'])
  end

  it 'retries an explicitly rejected post using the corrected channel and the original UUID' do
    row = request('Bandsaw')
    error = Slack::Web::Api::Errors::SlackError.new('channel_not_found')
    allow(slack).to receive(:send_slack_message).and_raise(error)
    scan
    uuid = CheckoutReminderDelivery.first.id
    allow(slack).to receive(:resource_managers_channel).and_return('corrected_channel')
    allow(slack).to receive(:send_slack_message).and_return({ 'channel' => 'CFIXED', 'ts' => '3.45' })
    scan
    expect(slack).not_to have_received(:find_post_receipt)
    expect(slack).to have_received(:send_slack_message).with(anything, 'corrected_channel', client_msg_id: uuid)
    expect(row.reload.reminders.fetch('1')).to include('channel' => 'CFIXED', 'ts' => '3.45', 'delivery_id' => uuid)
  end

  it 'schedules a fresh edit if a late Slack response arrives after its worker loses ownership' do
    band = request('Bandsaw')
    drill = request('Drill Press')
    scan
    band.update!(status: 'closed')
    allow(CheckoutRequestReminder).to receive(:with_member_lease) do |_, &block|
      checks = 0
      block.call(-> { checks += 1; raise SlackDeliveryLease::Busy if checks == 2 })
    end
    allow(slack).to receive(:update_slack_message) do
      drill.update!(status: 'deleted')
      # Simulate the new owner already having acknowledged both closures.
      ToolCheckoutRequest.collection.find('_id' => { '$in' => [band.id, drill.id] }).update_many(
        '$set' => { 'reminders.1.finalized' => true, 'reminder_open' => false })
    end
    CheckoutRequestReminder.finalize!(band)
    expect(band.reload.reminder_open).to be(true)
    expect(band.reminders.dig('1', 'finalized')).to be(false)
    allow(CheckoutRequestReminder).to receive(:with_member_lease).and_call_original
    allow(slack).to receive(:update_slack_message)
    CheckoutRequestReminderJob.perform_now
    expect(slack).to have_received(:update_slack_message).with('CRM', '1.123', include('No checkout requests'), resolved_channel: true)
    expect(band.reload.reminder_open).to be(false)
  end

  it 'finishes copying a saved receipt without reposting or looking up Slack history' do
    rows = [request('Bandsaw'), request('Drill Press')]
    batch = CheckoutReminderDelivery.create!(member_id: member.id, shop_id: shop.id, day: '2026-10-01', number: 1,
      request_ids: rows.map(&:id), member_name: member.fullname, shop_name: shop.name, attempted_at: day + 5.days,
      posted_channel: 'CRM', ts: '123.45', destination_mode: slack.message_destination_mode)
    rows.first.set(reminders: { '1' => { 'status' => 'sent', 'delivery_id' => batch.id, 'ts' => '123.45' } })
    scan
    expect(rows.map { |r| r.reload.reminders.fetch('1')['ts'] }).to eq(%w[123.45 123.45])
    expect(rows.all?(&:reminder_open)).to be(true)
    expect(CheckoutReminderDelivery.count).to eq(0)
    expect(slack).not_to have_received(:send_slack_message)
    expect(slack).not_to have_received(:find_post_receipt)
  end

  it 'continues to edit individual Slack receipts written before grouping' do
    row = request('Bandsaw')
    row.set(status: 'deleted', reminder_open: true, reminders: {
      '1' => { 'status' => 'sent', 'channel' => 'COLD', 'ts' => '88.99' }
    })
    CheckoutRequestReminder.finalize!(row)
    expect(edits).to eq([['COLD', '88.99', 'Checkout request from *Pat Member* for *Bandsaw* (2026-10-01) is no longer waiting: cancelled by the requester.']])
    expect(row.reload.reminder_open).to be(false)
  end
end
