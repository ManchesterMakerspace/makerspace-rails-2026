require 'rails_helper'
RSpec.describe EventbriteIntegration::Client do
  let(:http) { instance_double(Faraday::Connection) }
  before do
    allow(EventbriteIntegration::Configuration).to receive(:token).and_return("test-#{SecureRandom.uuid}")
    allow(EventbriteIntegration::Configuration).to receive(:organization_ids).and_return(['org'])
    allow(Faraday).to receive(:new).and_return(http)
  end
  it 'uses unchanged continuation tokens and retains filters' do
    client = described_class.new
    allow(client).to receive(:get).with('organizations/org/events/', { 'name_filter' => 'Weld' }).and_return({ 'pagination' => { 'has_more_items' => true, 'continuation' => 'opaque+/' }, 'events' => [] })
    allow(client).to receive(:get).with('organizations/org/events/', { 'name_filter' => 'Weld', 'continuation' => 'opaque+/' }).and_return({ 'pagination' => { 'has_more_items' => false }, 'events' => [] })
    pages = []
    client.each_page('organizations/org/events/', { 'name_filter' => 'Weld' }) { |_, token| pages << token }
    expect(pages).to eq(['opaque+/', nil])
  end
  it 'fails rather than looping on an unusable continuation' do
    client = described_class.new
    allow(client).to receive(:get).and_return({ 'pagination' => { 'has_more_items' => true } })
    expect { client.each_page('organizations/org/events/') { |_| } }.to raise_error(described_class::ApiError)
  end
  it 'shares a 429 cooldown even with a non-JSON response' do
    allow(http).to receive(:get).and_return(double(status: 429, headers: { 'retry-after' => '120' }, body: 'rate limited'))
    client = described_class.new
    expect { client.get('orders/1/') }.to raise_error(described_class::Deferred) { |e| expect(e.delay).to be >= 120 }
    expect { client.get('orders/1/') }.to raise_error(described_class::Deferred)
    expect(http).to have_received(:get).once
  end
  it 'applies a shared cooldown without Retry-After' do
    allow(http).to receive(:get).and_return(double(status: 429, headers: {}, body: '{}'))
    client = described_class.new
    expect { client.get('orders/1/') }.to raise_error(described_class::Deferred) { |e| expect(e.delay).to be_between(60, 70) }
    expect { described_class.new.get('orders/1/') }.to raise_error(described_class::Deferred)
    expect(http).to have_received(:get).once
  end
  [[3600, 2000], [86_400, 48_000]].each do |seconds, limit|
    it "enforces the rolling #{seconds}-second budget before sending" do
      client = described_class.new
      key = client.instance_variable_get(:@key)
      now = Time.now.to_f
      REDIS.zadd(key, Array.new(limit) { |i| [now - seconds / 2, "call#{i}"] })
      expect(http).not_to receive(:get)
      expect { client.get('orders/1/') }.to raise_error(described_class::Deferred)
    ensure
      REDIS.del(key)
    end
  end
  it 'waits at least half a second after completion across client instances' do
    calls = []
    allow(http).to receive(:get) do
      calls << Process.clock_gettime(Process::CLOCK_MONOTONIC)
      double(status: 200, headers: {}, body: '{"id":"1"}')
    end
    described_class.new.get('orders/1/')
    described_class.new.get('orders/1/')
    expect(calls.last - calls.first).to be >= 0.5
  end
  [302, 401, 503].each do |status|
    it "surfaces #{status} without automatic retries or redirects" do
      allow(http).to receive(:get).and_return(double(status: status, headers: { 'location' => 'https://example.com' }, body: '{}'))
      expect { described_class.new.get('orders/1/') }.to raise_error(described_class::ApiError) { |e| expect(e.status).to eq(status) }
      expect(http).to have_received(:get).once
    end
  end
  it 'never sends a second request while the shared token lease is occupied' do
    client = described_class.new
    EventbriteIntegration::Lease.with(client.instance_variable_get(:@key)) do
      expect(http).not_to receive(:get)
      expect { described_class.new.get('orders/1/') }.to raise_error(described_class::Deferred)
    end
  end
end
