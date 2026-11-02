require 'rails_helper'

RSpec.describe MemberReminderJob, type: :job do
  before do
    allow(Service::MemberReminders).to receive(:run!)
    allow(SystemConfig).to receive(:record_run)
  end

  it 'runs the service and records success' do
    described_class.perform_now
    expect(Service::MemberReminders).to have_received(:run!)
    expect(SystemConfig).to have_received(:record_run).with('member_reminders', success: true)
  end

  it 'records and reports failure' do
    error = StandardError.new('Mongo unavailable')
    allow(Service::MemberReminders).to receive(:run!).and_raise(error)
    allow(Honeybadger).to receive(:notify)

    expect { described_class.perform_now }.to raise_error(error)

    expect(SystemConfig).to have_received(:record_run).with('member_reminders', success: false)
    expect(Honeybadger).to have_received(:notify).with('MemberReminderJob failed', context: { error: 'Mongo unavailable' })
  end
end
