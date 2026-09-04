require 'rails_helper'

RSpec.describe VolunteerEventReminderJob, type: :job do
  let(:admin) { create(:member, :admin) }

  before do
    allow(Service::SlackConnector).to receive(:send_slack_message)
    allow(SystemConfig).to receive(:record_run)
  end

  it 'reminds about an open event whose date has passed' do
    event = VolunteerEvent.create!(
      title: 'Autumn Cleanup',
      credit_value: 1.0,
      created_by_id: admin.id,
      event_date: Date.today - 3,
      attendee_ids: [admin.id]
    )

    described_class.perform_now

    expect(Service::SlackConnector).to have_received(:send_slack_message).with(
      a_string_including('Autumn Cleanup', event.display_number, '3 days ago', '1 checked-in attendee'),
      VolunteerCredit.pending_slack_channel
    )
    expect(SystemConfig).to have_received(:record_run).with('volunteer_event_reminder', success: true)
  end

  it 'does not remind about an event scheduled for today or the future' do
    VolunteerEvent.create!(title: 'Today', credit_value: 1.0, created_by_id: admin.id, event_date: Date.today)
    VolunteerEvent.create!(title: 'Future', credit_value: 1.0, created_by_id: admin.id, event_date: Date.tomorrow)

    described_class.perform_now

    expect(Service::SlackConnector).not_to have_received(:send_slack_message)
  end

  it 'does not remind about an event with no date' do
    VolunteerEvent.create!(title: 'Undated', credit_value: 1.0, created_by_id: admin.id)

    described_class.perform_now

    expect(Service::SlackConnector).not_to have_received(:send_slack_message)
  end

  it 'does not remind about an already-closed event' do
    VolunteerEvent.create!(
      title: 'Closed already',
      credit_value: 1.0,
      created_by_id: admin.id,
      event_date: Date.today - 3,
      status: 'closed',
      closed_by_id: admin.id,
      closed_at: Time.now
    )

    described_class.perform_now

    expect(Service::SlackConnector).not_to have_received(:send_slack_message)
  end

  it 'continues reminding about other stale events when one Slack message fails, and still records success' do
    failing_event = VolunteerEvent.create!(title: 'Fails to notify', credit_value: 1.0, created_by_id: admin.id, event_date: Date.today - 1)
    other_event = VolunteerEvent.create!(title: 'Second stale event', credit_value: 1.0, created_by_id: admin.id, event_date: Date.today - 2)
    allow(Honeybadger).to receive(:notify)
    allow(Service::SlackConnector).to receive(:send_slack_message)
      .with(a_string_including(failing_event.title), anything).and_raise(StandardError.new('Slack down'))

    described_class.perform_now

    expect(Service::SlackConnector).to have_received(:send_slack_message)
      .with(a_string_including(other_event.title), anything)
    expect(Honeybadger).to have_received(:notify)
    expect(SystemConfig).to have_received(:record_run).with('volunteer_event_reminder', success: true)
  end
end
