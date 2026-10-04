# Load the complete Mongoid model and real reminder service without booting Rails:
# ruby -r rspec/autorun spec/unit/volunteer_task_status_notification_spec.rb
require 'active_support/all'
require 'active_support/testing/time_helpers'
require 'mongoid'
require_relative '../../app/services/service/volunteer_approval_reminder'

RSpec.describe 'Volunteer task cancellation and status notification integration' do
  include ActiveSupport::Testing::TimeHelpers

  let(:now) { Time.utc(2026, 10, 4, 16) }
  let(:actor) { double(fullname: 'Sam Reviewer') }
  let(:receipt) do
    {
      'ts' => '123.456', 'channel' => 'CORIGINAL', 'destination_mode' => 'production',
      'started_at' => now - 6.days, 'subject' => 'Task #17 for Pat Member', 'finalized' => true
    }
  end
  let(:task) do
    VolunteerTask.new(
      title: 'Sort lumber', description: 'Label the bins', task_number: 17,
      status: 'pending', completed_at: now - 6.days, approval_notification: receipt.deep_dup
    )
  end

  around { |example| Time.use_zone('America/New_York') { travel_to(now) { example.run } } }

  before do
    # These concerns/types have separate integration coverage. The tested task
    # methods come from the full model source, never extracted or reimplemented.
    stub_const('FixTicketBounty', Module.new)
    stub_const('SanitizesUserInput', Module.new)
    stub_const('FixTicketId', String)
    stub_const('VolunteerEvent', Class.new)
    stub_const('VolunteerTask', Class.new)
    stub_const('Service::SlackConnector', Module.new)
    stub_const('Service::ErrorReporter', Module.new)
    stub_const('SystemConfig', Class.new)
    stub_const('Member', Class.new)
    stub_const('VolunteerCredit', Class.new)
    allow(SystemConfig).to receive(:get).and_return('2.0')
    allow(Member).to receive(:find).and_return(double(fullname: 'Pat Member'))
    allow(VolunteerCredit).to receive(:create!)
    allow(Service::SlackConnector).to receive(:message_destination_mode).and_return('production')
    allow(Service::SlackConnector).to receive(:send_slack_message)
    allow(Service::SlackConnector).to receive(:update_slack_message).and_return('ok' => true)
    allow(Service::ErrorReporter).to receive(:notify)
    load File.expand_path('../../app/models/volunteer_task.rb', __dir__)

    stub_const('ApplicationJob', Class.new do
      def self.queue_as(_queue); end
    end)
    stub_const('VolunteerEventReminderJob', Class.new(ApplicationJob))
    load File.expand_path('../../app/jobs/volunteer_event_reminder_job.rb', __dir__)

    # Criteria are inspected without execution; fail before any accidental socket.
    allow(Mongo::Client).to receive(:new).and_raise('This unit spec must not connect to MongoDB')
    # Only the persistence boundaries are replaced. Mongoid fields, validation,
    # task lifecycle helpers, raw receipt selectors, and Slack text remain real.
    @persisted = task.attributes.deep_dup
    @raw_updates = []
    allow(task).to receive(:reload) do
      task.assign_attributes(@persisted.deep_dup)
      task
    end
    allow(task).to receive(:update!) do |attributes|
      task.assign_attributes(attributes)
      raise Mongoid::Errors::Validations.new(task) unless task.valid?

      @persisted = task.attributes.deep_dup
      task
    end
    collection = double('In-memory task collection')
    allow(VolunteerTask).to receive(:collection).and_return(collection)
    allow(collection).to receive(:find) do |selector|
      query = double('Atomic receipt update')
      allow(query).to receive(:find_one_and_update) do |update, **_options|
        @raw_updates << [selector.deep_dup, update.deep_dup]
        if matches?(@persisted, selector)
          apply_update!(@persisted, update)
          @persisted.deep_dup
        end
      end
      query
    end
  end

  def value_at(document, path)
    path.split('.').reduce(document) do |value, name|
      value.is_a?(Array) ? value[name.to_i] : value&.[](name)
    end
  end

  def matches?(document, selector)
    selector.all? do |path, expected|
      if path == '$or'
        expected.any? { |branch| matches?(document, branch) }
      else
        actual = value_at(document, path)
        if expected.is_a?(Hash) && expected.key?('$not')
          Array(actual).none? { |saved| matches?(saved, expected.fetch('$not').fetch('$elemMatch')) }
        elsif expected.is_a?(Hash) && expected.key?('$elemMatch')
          Array(actual).any? { |saved| matches?(saved, expected.fetch('$elemMatch')) }
        elsif expected.is_a?(Hash) && expected.key?('$lt')
          actual && actual < expected.fetch('$lt')
        else
          actual == expected
        end
      end
    end
  end

  def apply_update!(document, update)
    update.fetch('$set', {}).each do |path, value|
      names = path.split('.')
      container = names.length == 1 ? document : value_at(document, names.take(names.length - 1).join('.'))
      container.is_a?(Array) ? container[names.last.to_i] = value : container[names.last] = value
    end
    update.fetch('$push', {}).each { |path, value| value_at(document, path) << value }
  end

  def edit_status(new_status, reviewer: actor)
    notification = task.pending_review_outcome_for_status(new_status, actor: reviewer)
    task.update!(status: new_status)
    task.close_pending_review_notification!(notification)
    task.reload.approval_notification
  end

  it 'closes cancellation even when the pending receipt was already marked finalized' do
    task.cancel!

    expect(task.reload.status).to eq('cancelled')
    expect(task.approval_notification).to include(
      'ts' => receipt['ts'], 'channel' => receipt['channel'], 'outcome' => 'Task cancelled',
      'closed_at' => now, 'started_at' => now - 6.days, 'finalized' => true
    )
    expect(Service::SlackConnector).to have_received(:update_slack_message).with(
      'CORIGINAL', '123.456', a_string_including('Task cancelled', 'Review closed after 6 days.'),
      resolved_channel: true
    ).once
    expect(VolunteerCredit).not_to have_received(:create!)
    expect(Service::SlackConnector).not_to have_received(:send_slack_message)
  end

  it 'makes a failed cancellation final update selectable by the real job and retries in place' do
    allow(Service::SlackConnector).to receive(:update_slack_message).and_raise('Slack unavailable')

    expect { task.cancel! }.not_to raise_error
    expect(task.reload.status).to eq('cancelled')
    expect(task.approval_notification).to include('closed_at' => now, 'finalized' => false)
    criteria = VolunteerEventReminderJob.new.send(:reminder_tasks, now + 1.day)
    expect(matches?(@persisted, criteria.selector)).to be(true)
    expect(criteria.selector.fetch('$or')).to include('approval_notification.finalized' => false)

    allow(Service::SlackConnector).to receive(:update_slack_message).and_return('ok' => true)
    Service::VolunteerApprovalReminder.remind!(task, now: now + 1.day)

    expect(task.reload.approval_notification).to include('closed_at' => now, 'finalized' => true)
    expect(matches?(@persisted, criteria.selector)).to be(false)
    expect(Service::SlackConnector).to have_received(:update_slack_message).with(
      'CORIGINAL', '123.456', a_string_including('Task cancelled', 'Review closed after 6 days.'),
      resolved_channel: true
    ).twice
    expect(Service::SlackConnector).not_to have_received(:send_slack_message)
    expect(Service::ErrorReporter).to have_received(:notify).once
  end

  {
    'completed' => 'Task marked completed by Sam Reviewer through a status edit; no credits were issued by this edit',
    'denied' => 'Denied by Sam Reviewer through a task status edit',
    'cancelled' => 'Task cancelled by Sam Reviewer',
    'claimed' => 'Pending review ended by Sam Reviewer; task status changed to claimed',
    'available' => 'Pending review ended by Sam Reviewer; task status changed to available'
  }.each do |status, outcome|
    it "describes a generic edit to #{status} accurately without awarding credits" do
      notification = edit_status(status)

      expect(task.status).to eq(status)
      expect(notification).to include('outcome' => outcome, 'closed_at' => now, 'finalized' => true)
      expect(Service::SlackConnector).to have_received(:update_slack_message).with(
        'CORIGINAL', '123.456', a_string_including(outcome, 'Review closed after 6 days.'),
        resolved_channel: true
      ).once
      expect(VolunteerCredit).not_to have_received(:create!)
    end
  end

  it 'does not rewrite an already closed review when the completed task is later cancelled' do
    approved = receipt.merge('closed_at' => now - 1.day, 'outcome' => 'Approved earlier')
    task.update!(status: 'completed', approval_notification: approved)

    task.cancel!

    expect(task.reload.status).to eq('cancelled')
    expect(task.approval_notification).to eq(approved)
    expect(Service::SlackConnector).not_to have_received(:update_slack_message)
  end

  it 'stores a closed snapshot without posting when cancellation preceded the initial reminder' do
    task.update!(approval_notification: {})

    task.cancel!

    expect(task.reload.approval_notification).to include(
      'started_at' => now - 6.days, 'closed_at' => now, 'outcome' => 'Task cancelled', 'finalized' => true
    )
    expect(task.approval_notification['ts']).to be_nil
    expect(Service::SlackConnector).not_to have_received(:send_slack_message)
    expect(Service::SlackConnector).not_to have_received(:update_slack_message)
  end

  it 'leaves the receipt open for blank or unchanged status and title-only edits' do
    [nil, '', ' ', 'pending'].each do |status|
      expect(task.pending_review_outcome_for_status(status, actor: actor)).to eq({})
    end
    task.update!(title: 'Sort plywood')
    task.close_pending_review_notification!({})

    expect(task.reload.approval_notification).to eq(receipt)
    expect(Service::SlackConnector).not_to have_received(:update_slack_message)
  end

  it 'does not create review metadata when cancelling an unfinished claim with no receipt' do
    task.update!(status: 'claimed', completed_at: nil, approval_notification: {})

    task.cancel!

    expect(task.reload.status).to eq('cancelled')
    expect(task.approval_notification).to eq({})
    expect(Service::SlackConnector).not_to have_received(:update_slack_message)
  end

  it 'retains a pending receipt when a generic status edit fails Mongoid validation' do
    expect { edit_status('invalid-status') }.to raise_error(Mongoid::Errors::Validations)

    expect(task.reload.status).to eq('pending')
    expect(task.approval_notification).to eq(receipt)
    expect(Service::SlackConnector).not_to have_received(:update_slack_message)
  end

  it 'finalizes an outstanding receipt even if a previous edit already withdrew pending status' do
    task.update!(status: 'claimed')

    notification = edit_status('available', reviewer: nil)

    expect(notification).to include(
      'outcome' => 'Pending review ended; task status changed to available', 'closed_at' => now, 'finalized' => true
    )
    expect(Service::SlackConnector).to have_received(:update_slack_message).once
  end
end
