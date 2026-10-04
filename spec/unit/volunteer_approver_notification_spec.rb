# Exercise real delivery logic without booting Rails or contacting MongoDB/Slack:
# ruby -r rspec/autorun spec/unit/volunteer_approver_notification_spec.rb
require 'active_support/all'
require 'bson'
require_relative '../../app/services/volunteer_approver_notification'

RSpec.describe VolunteerApproverNotification do
  let(:now) { Time.utc(2026, 10, 4, 16) }
  let(:shop_id) { 'shop-wood' }
  let(:claimant) { double(id: 'claimant', fullname: 'Pat <Member>') }
  let(:manager) { double(id: 'rm-wood', manages_shop?: true, direct_notifications_suppressed?: false) }
  let(:second_manager) { double(id: 'rm-second', manages_shop?: true, direct_notifications_suppressed?: false) }
  let(:task) do
    VolunteerTask.new(id: 'claim-id', shop_id: shop_id, status: 'pending', title: 'Sort <lumber>',
      display_number: '#17', claimed_by_id: claimant.id, claimed_by: claimant, completed_at: now - 1.hour)
  end
  let(:event) do
    VolunteerEvent.new(id: 'event-id', shop_id: shop_id, status: 'open', title: 'Cleanup',
      display_number: 'E8', event_date: now.in_time_zone.to_date - 1, attendee_count: 3)
  end

  around { |example| Time.use_zone('America/New_York') { example.run } }

  before do
    @selectors = []
    @fail_receipt_writes = false
    record_class = Class.new do
      attr_accessor :id, :shop_id, :status, :title, :display_number, :claimed_by_id,
        :claimed_by, :completed_at, :event_date, :attendee_count, :approver_notifications
      def self.records; @records ||= []; end
      def initialize(attributes)
        @approver_notifications = {}
        attributes.each { |name, value| public_send("#{name}=", value) }
        self.class.records << self
      end
      def reload; self; end
      def document
        instance_variables.to_h do |name|
          value = instance_variable_get(name)
          value = Time.utc(value.year, value.month, value.day) if name == :@event_date && value
          [name == :@id ? '_id' : name.to_s.delete_prefix('@'), value]
        end
      end
    end
    stub_const('VolunteerTask', Class.new(record_class))
    stub_const('VolunteerEvent', Class.new(record_class))
    [VolunteerTask, VolunteerEvent].each do |model|
      collection = double('Atomic collection')
      allow(model).to receive(:collection).and_return(collection)
      allow(collection).to receive(:find) do |selector|
        @selectors << selector
        query = double('Atomic query')
        allow(query).to receive(:find_one_and_update) do |update, **_options|
          record = model.records.find { |candidate| matches?(candidate.document, selector) } unless
            @fail_receipt_writes && selector.keys.any? { |key| key.end_with?('.token') }
          if record
            update.fetch('$set').each { |path, value| set_path!(record, path, value) }
            record.document
          end
        end
        query
      end
    end
    stub_const('Member', Class.new)
    allow(Member).to receive(:where).with(role: 'resource_manager', resource_manager_shop_ids: shop_id)
      .and_return([manager, second_manager])
    stub_const('SlackUser', Class.new)
    allow(SlackUser).to receive(:find_by) { |member_id:| double(slack_id: "U-#{member_id}") }
    stub_const('ShortUrl', Class.new)
    allow(ShortUrl).to receive(:base_url).and_return('https://portal.example.org')
    stub_const('Service', Module.new)
    stub_const('Service::SlackConnector', Module.new)
    stub_const('Service::ErrorReporter', Module.new)
    allow(Service::SlackConnector).to receive(:send_slack_message)
      .and_return({ 'ts' => '123.456', 'channel' => 'DMCHANNEL' })
    allow(Service::SlackConnector).to receive(:message_destination_mode).and_return('production')
    allow(Service::ErrorReporter).to receive(:notify)
  end

  def value_at(document, path)
    path.split('.').reduce(document) { |value, name| value.is_a?(Hash) ? value[name] : nil }
  end

  def matches?(document, selector)
    selector.all? do |path, expected|
      if path == '$or'
        expected.any? { |condition| matches?(document, condition) }
      else
        actual = value_at(document, path)
        if expected.is_a?(Hash) && expected.key?('$exists')
          actual.present? == expected['$exists']
        elsif expected.is_a?(Hash) && expected.key?('$lt')
          actual && actual < expected['$lt']
        else
          actual == expected
        end
      end
    end
  end

  def set_path!(record, path, value)
    names = path.split('.')
    container = record.approver_notifications
    names[1...-1].each { |name| container = (container[name] ||= {}) }
    container[names.last] = value
  end

  def notify(record = task, at: now)
    described_class.notify!(record, now: at)
  end

  it 'DMs each assigned manager once with a link to the exact task claim' do
    notify
    notify(at: now + 1.day)
    expect(Service::SlackConnector).to have_received(:send_slack_message).with(
      a_string_including('Pat &lt;Member&gt;', '#17', 'Sort &lt;lumber&gt;',
        '<https://portal.example.org/volunteer?task=claim-id|Review claim>'), 'U-rm-wood').once
    expect(Service::SlackConnector).to have_received(:send_slack_message).with(anything, 'U-rm-second').once
    expect(task.approver_notifications.values.first.values).to all(include('state' => 'sent', 'ts' => '123.456'))
  end

  it 'targets a child claim and allows a later submission on the same task to notify again' do
    task.id = 'child-claim-id'
    notify
    task.completed_at = now + 1.day
    notify(at: now + 1.day)
    expect(Service::SlackConnector).to have_received(:send_slack_message).with(
      a_string_including('?task=child-claim-id'), 'U-rm-wood').twice
    expect(task.approver_notifications.length).to eq(2)
  end

  it 'sends one event review per manager after its date, regardless of attendance count' do
    notify(event)
    event.attendee_count = 10
    notify(event, at: now + 2.days)
    expect(Service::SlackConnector).to have_received(:send_slack_message).with(
      a_string_including('E8', '3 checked-in attendees', '?event=event-id', 'Review event attendance'), 'U-rm-wood').once
    expect(Service::SlackConnector).to have_received(:send_slack_message).exactly(2).times
  end

  it 'does not notify for unassigned shops, unfinished task claims, or already reviewed records' do
    task.shop_id = nil
    notify
    task.shop_id = shop_id
    task.status = 'claimed'
    notify
    task.status = 'completed'
    notify
    event.status = 'closed'
    notify(event)
    expect(Service::SlackConnector).not_to have_received(:send_slack_message)
  end

  it 'waits until the event date has passed and skips undated events' do
    [nil, now.in_time_zone.to_date, now.in_time_zone.to_date + 1].each do |date|
      event.event_date = date
      notify(event)
    end
    expect(Service::SlackConnector).not_to have_received(:send_slack_message)
  end

  it 'excludes managers who do not manage the shop and the task claimant themselves' do
    allow(manager).to receive(:manages_shop?).and_return(false)
    allow(second_manager).to receive(:id).and_return(claimant.id)
    notify
    expect(Service::SlackConnector).not_to have_received(:send_slack_message)
  end

  it 'honors the existing revoked/suspended member notification suppression' do
    allow(manager).to receive(:direct_notifications_suppressed?).and_return(true)
    notify
    expect(Service::SlackConnector).not_to have_received(:send_slack_message).with(anything, 'U-rm-wood')
    expect(Service::SlackConnector).to have_received(:send_slack_message).with(anything, 'U-rm-second').once
  end

  it 'does not mark an unlinked manager notified and delivers after their Slack account is linked' do
    allow(SlackUser).to receive(:find_by).with(member_id: manager.id).and_return(nil)
    notify
    expect(Service::SlackConnector).to have_received(:send_slack_message).once
    allow(SlackUser).to receive(:find_by).with(member_id: manager.id).and_return(double(slack_id: 'ULINKED'))
    notify
    expect(Service::SlackConnector).to have_received(:send_slack_message).with(anything, 'ULINKED').once
    expect(Service::SlackConnector).to have_received(:send_slack_message).with(anything, 'U-rm-second').once
  end

  it 'retries only a manager whose initial delivery failed' do
    attempts = 0
    allow(Service::SlackConnector).to receive(:send_slack_message).with(anything, 'U-rm-wood') do
      attempts += 1
      raise 'Slack unavailable' if attempts == 1
      { 'ts' => 'recovered.ts', 'channel' => 'DRECOVERED' }
    end
    notify
    notify(at: now + 1.day)
    expect(Service::SlackConnector).to have_received(:send_slack_message).with(anything, 'U-rm-wood').twice
    expect(Service::SlackConnector).to have_received(:send_slack_message).with(anything, 'U-rm-second').once
    expect(Service::ErrorReporter).to have_received(:notify).once
  end

  it 'does not accept an unsuccessful Slack response as a sent notification' do
    allow(Service::SlackConnector).to receive(:send_slack_message).and_return({ 'ok' => false })
    notify
    expect(task.approver_notifications.values.first.values).to all(include('state' => 'failed'))
  end

  it 'prevents a concurrent scan from posting another DM while delivery is in progress' do
    reentered = false
    allow(Service::SlackConnector).to receive(:send_slack_message) do
      unless reentered
        reentered = true
        notify
      end
      { 'ts' => '123.456', 'channel' => 'DMCHANNEL' }
    end
    notify
    expect(Service::SlackConnector).to have_received(:send_slack_message).with(anything, 'U-rm-wood').once
    expect(Service::SlackConnector).to have_received(:send_slack_message).with(anything, 'U-rm-second').once
  end

  it 'recovers an abandoned sending lease but does not steal a fresh lease' do
    allow(Service::SlackConnector).to receive(:send_slack_message).and_return({ 'ok' => false })
    notify
    receipt = task.approver_notifications.values.first[manager.id]
    receipt['state'] = 'sending'
    allow(Service::SlackConnector).to receive(:send_slack_message).and_return({ 'ts' => 'retry.ts', 'channel' => 'DRETRY' })
    notify(at: now + 1.minute)
    expect(Service::SlackConnector).to have_received(:send_slack_message).with(anything, 'U-rm-wood').once
    notify(at: now + 6.minutes)
    expect(Service::SlackConnector).to have_received(:send_slack_message).with(anything, 'U-rm-wood').twice
  end

  it 'keeps raw BSON selectors in UTC when called with the application timezone' do
    task.completed_at = (now - 1.hour).in_time_zone
    notify(at: now.in_time_zone)
    lease = @selectors.find { |selector| selector.key?('$or') }
    encoded = BSON::Document.new(lease).to_bson
    decoded = BSON::Document.from_bson(BSON::ByteBuffer.new(encoded.to_s))
    expect(decoded.fetch('completed_at')).to eq(now - 1.hour)
    cutoff = decoded.fetch('$or').last.values.find { |value| value.is_a?(Hash) }.fetch('$lt')
    expect(cutoff).to eq(now - 5.minutes)
  end

  it 'does not deliver for a replacement claim which raced with lease acquisition' do
    reloaded = 0
    allow(task).to receive(:reload) do
      reloaded += 1
      task.completed_at += 1.day if reloaded == 2
      task
    end
    notify
    expect(Service::SlackConnector).not_to have_received(:send_slack_message).with(anything, 'U-rm-wood')
    expect(task.approver_notifications.values.first[manager.id]['state']).to eq('obsolete')
  end

  it 'reports an uncertain post when the sent receipt cannot be persisted' do
    @fail_receipt_writes = true
    notify
    expect(Service::ErrorReporter).to have_received(:notify).with(
      an_object_having_attributes(message: a_string_including('delivery may have succeeded'))).twice
    expect(task.approver_notifications.values.first.values).to all(include('state' => 'sending'))
  end
end
