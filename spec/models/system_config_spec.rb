require 'rails_helper'

RSpec.describe SystemConfig do
  describe '.slack_conflict_scan_size' do
    it 'is 200 when unset' do
      expect(described_class.slack_conflict_scan_size).to eq(200)
    end

    it 'uses a saved whole number from 10 to 500' do
      %w[10 50 200 500].each do |size|
        described_class.set(described_class::SLACK_CONFLICT_SCAN_SIZE, size)
        expect(described_class.slack_conflict_scan_size).to eq(size.to_i)
      end
    end

    it 'falls back to the default for a stored value that is out of range or not a number' do
      ['9', '501', '0', '-5', '2.5', 'abc', ''].each do |size|
        described_class.set(described_class::SLACK_CONFLICT_SCAN_SIZE, size)
        expect(described_class.slack_conflict_scan_size).to eq(200)
      end
    end
  end

  describe '.scheduled_day_matches?' do
    it 'defaults to day 1 when unset' do
      travel_to(Time.zone.local(2026, 9, 1)) do
        expect(described_class.scheduled_day_matches?('some_job_day')).to be(true)
      end
      travel_to(Time.zone.local(2026, 9, 2)) do
        expect(described_class.scheduled_day_matches?('some_job_day')).to be(false)
      end
    end

    it 'uses the configured day when set' do
      described_class.set('some_job_day', '15')

      travel_to(Time.zone.local(2026, 9, 15)) do
        expect(described_class.scheduled_day_matches?('some_job_day')).to be(true)
      end
      travel_to(Time.zone.local(2026, 9, 1)) do
        expect(described_class.scheduled_day_matches?('some_job_day')).to be(false)
      end
    end

    it 'accepts a different default' do
      travel_to(Time.zone.local(2026, 9, 20)) do
        expect(described_class.scheduled_day_matches?('another_job_day', default: 20)).to be(true)
      end
    end
  end
end
