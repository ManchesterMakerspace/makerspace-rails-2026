require 'rails_helper'

RSpec.describe VolunteerApproverNotification do
  let(:now) { Time.zone.local(2026, 10, 4, 12) }
  let(:shop) { create(:shop) }
  let(:admin) { create(:member, :admin) }
  let(:claimant) { create(:member) }

  around do |example|
    Time.use_zone('America/New_York') { travel_to(now) { example.run } }
  end

  before do
    allow(Service::MemberProvisioning).to receive(:invite_slack)
    allow(VolunteerSlackCanvasSyncJob).to receive(:perform_later)
    allow(ShortUrl).to receive(:base_url).and_return('https://portal.example.org')
    allow(Service::SlackConnector).to receive(:message_destination_mode).and_return('production')
    allow(Service::SlackConnector).to receive(:send_slack_message) do |_text, slack_id|
      { 'ts' => "receipt-#{slack_id}", 'channel' => "D-#{slack_id}" }
    end
    allow(Service::ErrorReporter).to receive(:notify)
    allow(SystemConfig).to receive(:record_run)
  end

  def reviewer(slack_id: nil, shop_ids: [shop.id.to_s], invalidated: false, **attributes)
    manager = create(:member, **{
      role: 'resource_manager', resource_manager_shop_ids: shop_ids
    }.merge(attributes))
    if slack_id
      SlackUser.create!(member: manager, slack_id: slack_id, slack_email: manager.email,
        invalidated_at: invalidated ? now : nil)
    end
    manager
  end

  def task(**attributes)
    VolunteerTask.create!({
      title: 'Sort lumber', description: 'Label the bins', shop_id: shop.id,
      created_by_id: admin.id, status: 'pending', claimed_by_id: claimant.id,
      claimed_at: now - 1.day, completed_at: now - 1.hour
    }.merge(attributes))
  end

  def event(**attributes)
    VolunteerEvent.create!({
      title: 'Shop cleanup', shop_id: shop.id, created_by_id: admin.id,
      event_date: now.to_date, attendee_ids: [claimant.id, admin.id]
    }.merge(attributes))
  end

  def task_receipts(record)
    record.reload
    key = "submission_#{(record.completed_at.to_f * 1000).round}"
    record.approver_notifications.fetch(key)
  end

  it 'persists one DM receipt only for an actual resource manager assigned to the task shop' do
    assigned = reviewer(slack_id: 'UASSIGNED')
    reviewer(slack_id: 'UOTHER', shop_ids: [create(:shop).id.to_s])
    %w[member admin board_member].each { |role| reviewer(slack_id: "U#{role}", role: role) }
    claim = task

    2.times { described_class.notify!(claim, now: now) }

    expect(Service::SlackConnector).to have_received(:send_slack_message).once.with(
      a_string_including(claimant.fullname, claim.display_number,
        "https://portal.example.org/volunteer?task=#{claim.id}"), 'UASSIGNED'
    )
    receipts = task_receipts(claim)
    expect(receipts.keys).to eq([assigned.id.to_s])
    expect(receipts.fetch(assigned.id.to_s)).to include(
      'state' => 'sent', 'ts' => 'receipt-UASSIGNED', 'channel' => 'D-UASSIGNED',
      'sent_at' => now, 'destination_mode' => 'production'
    )
  end

  it 'excludes missing, blank and invalidated Slack links, suppressed managers and the claimant' do
    assigned = reviewer(slack_id: 'UELIGIBLE')
    reviewer
    reviewer(slack_id: '')
    reviewer(slack_id: 'UINVALIDATED', invalidated: true)
    %w[revoked suspended].each { |status| reviewer(slack_id: "U#{status}", status: status) }
    self_reviewer = reviewer(slack_id: 'USELF')
    claim = task(claimed_by_id: self_reviewer.id)

    described_class.notify!(claim, now: now)

    expect(Service::SlackConnector).to have_received(:send_slack_message).once.with(anything, 'UELIGIBLE')
    expect(task_receipts(claim).keys).to eq([assigned.id.to_s])
  end

  it 'notifies immediately on a child claim submission and the job does not resend its DM' do
    assigned = reviewer(slack_id: 'UCHILD')
    parent = task(status: 'repeatable', claimed_by_id: nil, claimed_at: nil, completed_at: nil)
    claim = parent.claim!(claimant)
    expect(Service::SlackConnector).not_to have_received(:send_slack_message)

    claim.mark_pending!(claimant)
    VolunteerEventReminderJob.perform_now

    expect(claim.reload.status).to eq('pending')
    expect(claim.parent_task_id).to eq(parent.id)
    expect(task_receipts(claim).fetch(assigned.id.to_s)['state']).to eq('sent')
    expect(parent.reload.approver_notifications).to be_empty
    expect(Service::SlackConnector).to have_received(:send_slack_message).once.with(
      a_string_including("https://portal.example.org/volunteer?task=#{claim.id}"), 'UCHILD'
    )
  end

  it 'sends one aggregate event review DM after its date, including across repeated job runs' do
    assigned = reviewer(slack_id: 'UEVENT')
    activity = event
    excluded = [
      event(title: 'Future', event_date: now.to_date + 3),
      event(title: 'Undated', event_date: nil),
      event(title: 'Closed', event_date: now.to_date - 1, status: 'closed'),
      event(title: 'Unscoped', event_date: now.to_date - 1, shop_id: nil)
    ]
    VolunteerEventReminderJob.perform_now
    expect(Service::SlackConnector).not_to have_received(:send_slack_message)
    expect(activity.reload.approver_notifications).to be_empty

    travel 1.day
    2.times { VolunteerEventReminderJob.perform_now }

    expect(Service::SlackConnector).to have_received(:send_slack_message).once.with(
      a_string_including(activity.display_number, '2 checked-in attendees',
        "https://portal.example.org/volunteer?event=#{activity.id}"), 'UEVENT'
    )
    expect(activity.reload.approver_notifications.fetch('event').fetch(assigned.id.to_s)).to include(
      'state' => 'sent', 'ts' => 'receipt-UEVENT', 'channel' => 'D-UEVENT'
    )
    excluded.each { |record| expect(record.reload.approver_notifications).to be_empty }
  end

  it 'retries only the manager whose DM failed and preserves another manager\'s successful receipt' do
    successful = reviewer(slack_id: 'USUCCESS')
    failed = reviewer(slack_id: 'UFAILURE')
    claim = task
    allow(Service::SlackConnector).to receive(:send_slack_message).with(anything, 'UFAILURE')
      .and_raise(StandardError, 'Slack unavailable')

    expect { described_class.notify!(claim, now: now) }.not_to raise_error
    receipts = task_receipts(claim)
    expect(receipts.fetch(successful.id.to_s)['state']).to eq('sent')
    expect(receipts.fetch(failed.id.to_s)['state']).to eq('failed')

    allow(Service::SlackConnector).to receive(:send_slack_message).with(anything, 'UFAILURE')
      .and_return({ 'ts' => 'retry.ts', 'channel' => 'D-UFAILURE' })
    described_class.notify!(claim, now: now)

    expect(Service::SlackConnector).to have_received(:send_slack_message).with(anything, 'USUCCESS').once
    expect(Service::SlackConnector).to have_received(:send_slack_message).with(anything, 'UFAILURE').twice
    expect(task_receipts(claim).fetch(failed.id.to_s)).to include('state' => 'sent', 'ts' => 'retry.ts')
    expect(Service::ErrorReporter).to have_received(:notify).with(an_instance_of(StandardError))
  end

  it 'does not notify for unscoped tasks or work that is not submitted for approval' do
    reviewer(slack_id: 'URM')
    records = [
      task(shop_id: nil), task(status: 'claimed', completed_at: nil),
      task(status: 'completed'), task(completed_at: nil)
    ]

    records.each { |record| described_class.notify!(record, now: now) }

    expect(Service::SlackConnector).not_to have_received(:send_slack_message)
    records.each { |record| expect(record.reload.approver_notifications).to be_empty }
  end
end
