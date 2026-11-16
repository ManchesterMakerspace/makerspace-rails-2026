require 'rails_helper'
require 'rake'

RSpec.describe 'eventbrite announcement tasks' do
  let(:task) { Rake::Task['eventbrite:announce_upcoming'] }
  let(:service) { instance_double(EventbriteIntegration::Announcements) }
  let(:delivery) { EventbriteSlackDelivery.create!(organization_id: 'org', scope_id: 'one', event_ids: ['one'], kind: 'reminder', mode: Service::SlackConnector.message_destination_mode) }

  before do
    Rails.application.load_tasks unless Rake::Task.task_defined?('eventbrite:announce_upcoming')
    task.reenable
    allow(EventbriteIntegration::Backfill::WaitingClient).to receive(:new)
    allow(EventbriteIntegration::Announcements).to receive(:new).and_return(service)
    allow(service).to receive(:upcoming).with('1').and_return([delivery])
    allow(EventbriteIntegration::Configuration).to receive(:validate!)
  end

  it 'explains existing terminal failures rather than silently skipping them' do
    delivery.set(failed_at: Time.current, last_error: 'Slack::Web::Api::Errors::NotInChannel: not_in_channel', attempts: 1)
    expect(Service::SlackConnector).not_to receive(:client)
    expect do
      expect { task.invoke }.to raise_error(/see delivery details above/)
    end.to output(/#{delivery.id}.*"previously_failed":true.*not_in_channel.*retry_failed/m).to_stderr
    expect(delivery.reload.failed_at).to be_present
  end

  it 'reports deferred work without claiming a failed attempt' do
    delivery.set(due_at: 90.seconds.from_now, last_error: 'TooManyRequestsError: Retry after 90 seconds')
    expect(Service::SlackConnector).not_to receive(:client)
    expect do
      expect { task.invoke }.to raise_error(/see delivery details above/)
    end.to output(/Eventbrite Slack deferred:.*"previously_failed":false.*Retry after 90/m).to_stderr
  end

  it 'shows the configured and effective destination even when existing failures prevent a new request' do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('SLACK_ENV').and_return('development')
    SystemConfig.set('slack_channel_upcoming_events', 'general')
    delivery.set(failed_at: Time.current, last_error: 'ChannelNotFound')
    expect(Service::SlackConnector).not_to receive(:client)
    expect do
      expect { task.invoke }.to raise_error(/see delivery details above/)
    end.to output(a_string_including('"mode":"test","configured_channel":"general","effective_channel":"test_channel"')).to_stderr
  end

  it 'resets only known Slack failures and preserves ambiguous sends' do
    delivery.set(failed_at: Time.current, last_error: 'not_in_channel', attempts: 1)
    ambiguous = EventbriteSlackDelivery.create!(organization_id: 'org', scope_id: 'two', kind: 'reminder', mode: delivery.mode,
      failed_at: Time.current, sending_at: Time.current, last_error: 'AMBIGUOUS_SEND')
    retry_task = Rake::Task['eventbrite:retry_failed']
    retry_task.reenable
    expect { retry_task.invoke }.to output(/Reset 1 known Slack failures.*Reset 0 failed Eventbrite deliveries/m).to_stdout
    expect(delivery.reload.failed_at).to be_nil
    expect(ambiguous.reload.failed_at).to be_present
    expect(ambiguous.sending_at).to be_present
  end
end
