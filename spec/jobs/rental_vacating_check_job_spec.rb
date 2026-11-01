require 'rails_helper'

RSpec.describe RentalVacatingCheckJob do
  before do
    allow(Service::SlackConnector).to receive(:send_slack_message)
    allow(Service::ErrorReporter).to receive(:notify)
  end

  let(:channel) { Service::SlackConnector.members_relations_channel }
  let(:past_ms) { (Time.current - 53.days).to_i * 1000 }
  let(:future_ms) { (Time.current + 20.days).to_i * 1000 }

  it 'posts one roll-up for overdue vacating rentals and member-reported vacated ones, and changes nothing' do
    overdue = create(:rental, status: 'vacating', expiration: past_ms)
    waiting = create(:rental, status: 'awaiting_verification', vacated_reported_at: 3.days.ago)
    create(:rental, status: 'vacating', expiration: future_ms)
    create(:rental, status: 'active', expiration: past_ms)
    create(:rental, status: 'cancelled', expiration: past_ms)

    described_class.perform_now

    expect(Service::SlackConnector).to have_received(:send_slack_message).once.with(
      a_string_including('Rentals waiting on staff (2)', overdue.number, waiting.number, 'waiting 3 days', '53 days ago', 'Verify Vacated'),
      channel
    )
    expect(overdue.reload.status).to eq('vacating')
    expect(waiting.reload.status).to eq('awaiting_verification')
  end

  it 'says so when a member reported before the reminder tracked the date' do
    create(:rental, status: 'awaiting_verification')

    described_class.perform_now

    expect(Service::SlackConnector).to have_received(:send_slack_message)
      .with(a_string_including('waiting since before this reminder existed'), channel)
  end

  it 'posts nothing when nothing is waiting, and still records the run' do
    create(:rental, status: 'vacating', expiration: future_ms)

    described_class.perform_now

    expect(Service::SlackConnector).not_to have_received(:send_slack_message)
    expect(SystemConfig.job_status('rental_vacating_check')).to include(last_run_status: 'success')
  end

  it 'records a failure and reports it when the post fails' do
    create(:rental, status: 'awaiting_verification', vacated_reported_at: 1.day.ago)
    allow(Service::SlackConnector).to receive(:send_slack_message).and_raise('Slack down')

    expect { described_class.perform_now }.to raise_error('Slack down')

    expect(SystemConfig.job_status('rental_vacating_check')).to include(last_run_status: 'failure')
    expect(Service::ErrorReporter).to have_received(:notify)
  end
end
