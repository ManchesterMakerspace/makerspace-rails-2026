require 'rails_helper'

RSpec.describe Service::ErrorReporter do
  describe '.notify' do
    it 'logs an exception before notifying Honeybadger' do
      error = StandardError.new('remote service unavailable')
      context = { member_id: '123' }

      expect(Rails.logger).to receive(:error).with(
        a_string_including('[ErrorReporter] StandardError: remote service unavailable', 'member_id', '123')
      ).ordered
      expect(Honeybadger).to receive(:notify).with(error, context: context).ordered

      described_class.notify(error, context: context)
    end

    it 'logs string error descriptions' do
      allow(Honeybadger).to receive(:notify)

      expect(Rails.logger).to receive(:error).with('[ErrorReporter] scheduled task failed')

      described_class.notify('scheduled task failed')
    end
  end
end
