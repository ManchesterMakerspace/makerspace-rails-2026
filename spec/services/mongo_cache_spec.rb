require "rails_helper"

RSpec.describe MongoCache do
  let(:cache) { ActiveSupport::Cache::MemoryStore.new }

  before do
    allow(Rails).to receive(:cache).and_return(cache)
    allow(SystemConfig).to receive(:raw_get)
      .with(SystemConfig::MONGO_CACHE_TTL_HOURS)
      .and_return(nil)
  end

  it "executes a cold block once and returns the warm materialized value" do
    calls = 0
    first = described_class.fetch("shops", dependencies: ["shops"]) do
      calls += 1
      [{ "id" => "one" }]
    end
    second = described_class.fetch("shops", dependencies: ["shops"]) do
      calls += 1
      [{ "id" => "two" }]
    end

    expect(first).to eq([{ "id" => "one" }])
    expect(second).to eq(first)
    expect(calls).to eq(1)
  end

  it "uses the configured TTL within the supported range" do
    allow(SystemConfig).to receive(:raw_get).and_return("12")
    expect(described_class.ttl).to eq(12.hours)
  end

  it "invalidates dependency generations" do
    calls = 0
    2.times do
      described_class.fetch("tools", dependencies: ["tools"]) { calls += 1; calls }
    end
    described_class.invalidate("tools")
    value = described_class.fetch("tools", dependencies: ["tools"]) { calls += 1; calls }

    expect(value).to eq(2)
  end

  it "rejects a lazy Mongoid criteria object" do
    criteria = Mongoid::Criteria.new(Member)
    expect {
      described_class.fetch("bad", dependencies: ["members"]) { criteria }
    }.to raise_error(ArgumentError, /materialize Mongoid::Criteria/)
  end

  it "fails open when Redis is unavailable" do
    allow(cache).to receive(:fetch).and_raise(Redis::CannotConnectError.new("down"))
    allow(Rails.logger).to receive(:warn)

    expect(
      described_class.fetch("fallback", dependencies: ["shops"]) { ["database"] }
    ).to eq(["database"])
  end

  it "uses a race-condition window to prevent cache stampedes" do
    allow(cache).to receive(:fetch).and_call_original

    described_class.fetch("stampede", dependencies: []) { ["value"] }

    expect(cache).to have_received(:fetch).with(
      array_including("stampede"),
      hash_including(race_condition_ttl: MongoCache::RACE_CONDITION_TTL)
    )
  end
end
