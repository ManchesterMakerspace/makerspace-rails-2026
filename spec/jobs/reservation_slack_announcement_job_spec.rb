require 'rails_helper'

RSpec.describe ReservationSlackAnnouncementJob do
  before do
    allow(Service::ErrorReporter).to receive(:notify)
  end

  it 'records a successful reconciliation' do
    allow(Service::ReservationSlackAnnouncements).to receive(:sync!).with(date: nil).and_return(:synced)
    described_class.perform_now
    expect(SystemConfig.job_status('reservation_slack_announcements')[:last_run_status]).to eq('success')
  end

  it 'does not overwrite status for a suppressed or stale invocation' do
    allow(Service::ReservationSlackAnnouncements).to receive(:sync!).with(date: '2026-11-19').and_return(:skipped)
    described_class.perform_now('2026-11-19')
    expect(SystemConfig.job_status('reservation_slack_announcements')).to be_nil
  end

  it 'records and reports partial delivery failure' do
    allow(Service::ReservationSlackAnnouncements).to receive(:sync!).and_raise(StandardError, 'Slack unavailable')
    expect { described_class.new.perform }.to raise_error(StandardError, 'Slack unavailable')
    expect(SystemConfig.job_status('reservation_slack_announcements')[:last_run_status]).to eq('failure')
    expect(Service::ErrorReporter).to have_received(:notify)
  end
end
