require 'rails_helper'

RSpec.describe VolunteerTask, 'weekday availability', type: :model do
  let(:member) { create(:member, :current) }
  let(:admin) { create(:member, :admin, :current) }
  let(:attributes) { { title: 'Weekly cleanup', description: 'Organize supplies', created_by_id: admin.id } }

  around do |example|
    # UTC is already Friday here; the business day is still Thursday in New York.
    travel_to(Time.utc(2026, 11, 20, 1)) { example.run }
  end

  before do
    ActiveJob::Base.queue_adapter = :test
    allow(Service::SlackConnector).to receive(:send_slack_message)
    allow(Service::SlackConnector).to receive(:enque_message)
  end

  it 'defaults to any day and accepts every valid weekday without truncating invalid values' do
    expect(described_class.new(attributes).day_of_week).to be_nil
    (0..6).each do |weekday|
      expect(described_class.new(attributes.merge(status: 'repeatable', day_of_week: weekday))).to be_valid
    end
    [-1, 7, 1.5, true, false, 'Monday', '2.5'].each do |value|
      task = described_class.new(attributes.merge(status: 'repeatable', day_of_week: value))
      expect(task).not_to be_valid
      expect(task.errors[:day_of_week]).to be_present
    end
    expect(described_class.new(attributes.merge(day_of_week: '0')).day_of_week).to eq(0)
    expect(described_class.new(attributes.merge(day_of_week: '')).day_of_week).to be_nil
  end

  it 'filters each multi-use status by the Eastern weekday while preserving any-day and standard tasks' do
    always = described_class.create!(attributes)
    # An irrelevant value on a single-use task must not impose a new restriction.
    standard = described_class.create!(attributes.merge(day_of_week: 5))
    matching = %w[reusable repeatable recurring].map do |status|
      described_class.create!(attributes.merge(status: status, days: status == 'recurring' ? 7 : nil, day_of_week: 4))
    end
    any_day = described_class.create!(attributes.merge(status: 'repeatable'))
    %w[reusable repeatable recurring].each do |status|
      described_class.create!(attributes.merge(status: status, days: status == 'recurring' ? 7 : nil, day_of_week: 5))
    end
    described_class.create!(attributes.merge(status: 'recurring', days: 7, day_of_week: 4, next_available: Date.today + 1))

    expect(described_class.business_date).to eq(Date.new(2026, 11, 19))
    expect(described_class.claimable.pluck(:id)).to match_array([always, standard, any_day, *matching].map(&:id))
  end

  %w[reusable repeatable recurring].each do |status|
    %w[member admin board_member resource_manager].each do |role|
      it "rejects an off-day #{status} claim by #{role} without creating a child or changing cooldown" do
        actor = create(:member, :current, role: role)
        task = described_class.create!(attributes.merge(status: status, days: status == 'recurring' ? 7 : nil, day_of_week: 5))
        original = task.attributes
        expect { task.claim!(actor) }.to raise_error(Error::Forbidden)
        expect(described_class.where(parent_task_id: task.id)).to be_empty
        expect(task.reload.attributes).to eq(original)
      end
    end

    it "allows a matching-day #{status} claim without restricting its child on another day" do
      task = described_class.create!(attributes.merge(status: status, days: status == 'recurring' ? 7 : nil, day_of_week: 4))
      child = task.claim!(member)
      expect(child.day_of_week).to be_nil
      travel_to(Time.utc(2026, 11, 20, 17))
      expect(child.weekday_available?).to be(true)
      child.mark_pending!(member)
      expect(child.reload.status).to eq('pending')
    end
  end

  it 'preserves recurring cooldown and reusable once-per-member checks on matching days' do
    recurring = described_class.create!(attributes.merge(status: 'recurring', days: 7, day_of_week: 4, next_available: Date.today + 1))
    expect { recurring.claim!(member) }.to raise_error(Error::CoolingDown)
    reusable = described_class.create!(attributes.merge(status: 'reusable', day_of_week: 4))
    reusable.claim!(member)
    expect { reusable.claim!(member) }.to raise_error(Error::AlreadyClaimed)
  end

  it 'allows cancelling a scheduled parent without invalidating its saved weekday metadata' do
    task = described_class.create!(attributes.merge(status: 'repeatable', day_of_week: 4))
    task.cancel!
    expect(task.reload.status).to eq('cancelled')
    expect(task.day_of_week).to eq(4)
  end

  [[Time.utc(2026, 3, 8, 4, 30), Date.new(2026, 3, 7)],
   [Time.utc(2026, 3, 8, 5), Date.new(2026, 3, 8)],
   [Time.utc(2026, 11, 1, 3, 30), Date.new(2026, 10, 31)],
   [Time.utc(2026, 11, 1, 4), Date.new(2026, 11, 1)]].each do |instant, date|
    it "uses the Eastern local date across the DST boundary at #{instant}" do
      expect(described_class.business_date(time: instant)).to eq(date)
    end
  end
end
