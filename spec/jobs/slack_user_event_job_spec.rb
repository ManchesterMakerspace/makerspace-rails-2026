require 'rails_helper'

RSpec.describe SlackUserEventJob, type: :job do
  it 'retries transient processing failures' do
    error = StandardError.new('temporary processing failure')
    allow(Service::SlackUserEvents).to receive(:process).and_raise(error)

    expect do
      described_class.perform_now('Ev-retry', { 'type' => 'user_change' })
    end.to have_enqueued_job(described_class).with(
      'Ev-retry',
      { 'type' => 'user_change' }
    )
  end
end
