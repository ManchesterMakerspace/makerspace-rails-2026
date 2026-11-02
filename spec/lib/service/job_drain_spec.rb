require 'rails_helper'

RSpec.describe Service::JobDrain do
  around do |example|
    original = ActiveJob::Base.queue_adapter
    begin
      example.run
    ensure
      ActiveJob::Base.queue_adapter = original
    end
  end

  let(:finished) { Concurrent::AtomicBoolean.new(false) }

  def stub_probe_job(seconds)
    done = finished
    stub_const('DrainProbeJob', Class.new(ActiveJob::Base) do
      define_method(:perform) { sleep seconds; done.make_true }
    end)
  end

  it 'waits for jobs queued on the in-process adapter, so a runner that exits does not drop them' do
    ActiveJob::Base.queue_adapter = :async
    stub_probe_job(0.3).perform_later

    expect(finished.true?).to be(false)
    expect(described_class.wait!).to be(true)
    expect(finished.true?).to be(true)
  end

  it 'gives up after the timeout instead of holding the process' do
    ActiveJob::Base.queue_adapter = :async
    stub_probe_job(2).perform_later
    allow(Rails.logger).to receive(:warn)

    started = Time.now
    expect(described_class.wait!(timeout: 0.2)).to be(false)

    expect(Time.now - started).to be < 1.5
    expect(Rails.logger).to have_received(:warn).with(/still running/)
  end

  it 'does nothing for any other queue adapter' do
    ActiveJob::Base.queue_adapter = :test

    expect(described_class.wait!).to be(false)
  end
end
