# Inspect real Mongoid criteria without connecting to a database:
# ruby -r rspec/autorun spec/unit/volunteer_event_reminder_queries_spec.rb
require 'active_support/all'
require 'mongoid'
require_relative '../../app/services/service/volunteer_approval_reminder'

RSpec.describe 'Volunteer approval reminder job query selection' do
  let(:now) { Time.utc(2026, 10, 4, 16) }
  let(:job) { VolunteerEventReminderJob.new }

  before do
    stub_const('ApplicationJob', Class.new do
      def self.queue_as(_queue); end
    end)
    stub_const('VolunteerEventReminderJob', Class.new(ApplicationJob))
    load File.expand_path('../../app/jobs/volunteer_event_reminder_job.rb', __dir__)

    %w[VolunteerTask VolunteerEvent].each do |name|
      model_class = Class.new do
        include Mongoid::Document
        field :status, type: String
        field :completed_at, type: Time
        field :event_date, type: Date
        field :approval_notification, type: Hash, default: {}
        field :approval_notification_history, type: Array, default: []
      end
      stub_const(name, model_class)
    end
    # Any accidental criteria evaluation must fail before opening a socket.
    allow(Mongo::Client).to receive(:new).and_raise('Unit query specs must not connect to MongoDB')
  end

  def unfinished_selectors
    [
      { 'approval_notification.finalized' => false },
      { 'approval_notification_history' => { '$elemMatch' => { 'finalized' => false } } }
    ]
  end

  it 'selects submitted tasks strictly older than five days plus retryable final notifications' do
    selector = job.send(:reminder_tasks, now).selector
    overdue, *retries = selector.fetch('$or')
    expect(overdue).to include('status' => 'pending')
    expect(overdue.fetch('completed_at')).to include('$lt' => now - 5.days)
    expect(retries).to eq(unfinished_selectors)
  end

  it 'selects open events strictly more than five calendar days after their dates plus final retries' do
    selector = job.send(:reminder_events, now).selector
    overdue, *retries = selector.fetch('$or')
    expect(overdue).to include('status' => 'open')
    # Mongoid serializes a Date field to its UTC midnight BSON representation.
    expect(overdue.fetch('event_date').fetch('$lt')).to eq(Time.utc(2026, 9, 29))
    expect(retries).to eq(unfinished_selectors)
  end

  it 'does not apply a pending or open status filter to saved final-outcome retry branches' do
    [job.send(:reminder_tasks, now), job.send(:reminder_events, now)].each do |criteria|
      expect(criteria.selector.fetch('$or').drop(1)).to eq(unfinished_selectors)
    end
  end
end
