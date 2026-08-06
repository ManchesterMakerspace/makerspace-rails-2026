require "rails_helper"

RSpec.describe Service::SlackChannelCache do
  let(:client) { instance_double(Slack::Web::Client) }
  let(:first_page) do
    double(
      channels: [
        double(
          id: "C123",
          name: "wood-shop",
          topic: double(value: "Woodworking discussion"),
          purpose: double(value: "Coordinate the wood shop")
        )
      ],
      response_metadata: double(next_cursor: "next")
    )
  end
  let(:second_page) do
    double(
      channels: [
        double(
          id: "C456",
          name: "metal-shop",
          topic: double(value: "Metalworking discussion"),
          purpose: double(value: "Coordinate the metal shop")
        )
      ],
      response_metadata: double(next_cursor: "")
    )
  end

  before do
    allow(Service::SlackConnector).to receive(:client).and_return(client)
    allow(REDIS).to receive(:get).and_return(nil)
    allow(REDIS).to receive(:set).and_return(true)
    allow(REDIS).to receive(:del).and_return(1)
    allow(REDIS).to receive(:rename).and_return(true)
    allow(REDIS).to receive(:multi) do |&block|
      block.call(REDIS)
      []
    end
    allow(REDIS).to receive(:scan_each).and_return([].each)
  end

  it "normalizes names and caches every channel encountered until the target is found" do
    allow(client).to receive(:conversations_list)
      .and_return(first_page, second_page)

    result = described_class.lookup("#METAL-SHOP", refresh_on_miss: true)

    expect(result).to include(
      "id" => "C456",
      "name" => "metal-shop",
      "topic" => "Metalworking discussion",
      "purpose" => "Coordinate the metal shop"
    )
    expect(REDIS).to have_received(:set).with(
      "slack:public_channel:wood-shop",
      include('"id":"C123"'),
      ex: 1000.hours.to_i
    )
    expect(REDIS).to have_received(:set).with(
      "slack:public_channel:metal-shop",
      include('"id":"C456"'),
      ex: 1000.hours.to_i
    )
  end

  it "returns cached channel details without calling Slack" do
    allow(REDIS).to receive(:get).with("slack:public_channel:wood-shop")
      .and_return(JSON.generate(
        id: "C123", name: "wood-shop", topic: "Topic", purpose: "Purpose"
      ))

    expect(described_class.lookup("#wood-shop")).to include("id" => "C123")
    expect(client).not_to receive(:conversations_list)
  end

  it "reports the current key count and last full update" do
    allow(REDIS).to receive(:get).with(described_class::STATUS_KEY)
      .and_return(JSON.generate(lastUpdatedAt: "2026-07-28T12:00:00Z"))
    allow(REDIS).to receive(:scan_each)
      .with(match: "slack:public_channel:*")
      .and_return(%w[channel-one channel-two].each)

    expect(described_class.status).to eq(
      available: true,
      total_channels: 2,
      last_updated_at: "2026-07-28T12:00:00Z"
    )
  end

  it "finishes scanning before replacing stale keys and records cache metadata" do
    events = []
    allow(REDIS).to receive(:scan_each)
      .with(match: "slack:public_channel:*")
      .and_return(%w[slack:public_channel:old].each)
    allow(client).to receive(:conversations_list) do
      events << :scan
      events.count(:scan) == 1 ? first_page : second_page
    end
    allow(REDIS).to receive(:del) do
      events << :clear
      1
    end

    expect(described_class.rebuild!).to eq(2)

    expect(events.index(:clear)).to be > events.rindex(:scan)
    expect(REDIS).to have_received(:del)
      .with("slack:public_channel:old")
    expect(REDIS).to have_received(:set).with(
      a_string_matching(
        /slack:public_channel_cache:rebuild:[^:]+:wood-shop/
      ),
      include('"id":"C123"'),
      ex: 1000.hours.to_i
    )
    expect(REDIS).to have_received(:set).with(
      a_string_matching(
        /slack:public_channel_cache:rebuild:[^:]+:metal-shop/
      ),
      include('"id":"C456"'),
      ex: 1000.hours.to_i
    )
    expect(REDIS).to have_received(:rename).with(
      a_string_matching(/:wood-shop\z/),
      "slack:public_channel:wood-shop"
    )
    expect(REDIS).to have_received(:rename).with(
      a_string_matching(/:metal-shop\z/),
      "slack:public_channel:metal-shop"
    )
    expect(REDIS).to have_received(:set).with(
      described_class::STATUS_KEY,
      include('"totalChannels":2', '"lastUpdatedAt"'),
      ex: 1000.hours.to_i
    )
  end

  it "preserves the existing cache when Slack pagination fails" do
    requests = 0
    allow(client).to receive(:conversations_list) do
      requests += 1
      raise StandardError, "temporary Slack failure" if requests == 2

      first_page
    end

    expect { described_class.rebuild! }
      .to raise_error(RuntimeError, "Slack public-channel cache rebuild failed")

    expect(REDIS).not_to have_received(:scan_each)
    expect(REDIS).not_to have_received(:del)
    expect(REDIS).not_to have_received(:set)
  end

  it "fails without promoting or clearing when a staged Redis write fails" do
    allow(REDIS).to receive(:scan_each)
      .with(match: "slack:public_channel:*")
      .and_return(%w[slack:public_channel:old].each)
    allow(client).to receive(:conversations_list)
      .and_return(first_page, second_page)
    allow(REDIS).to receive(:set) do |key, _value, **_options|
      if key.match?(/:metal-shop\z/)
        raise Redis::CommandError, "temporary Redis failure"
      end

      true
    end

    expect { described_class.rebuild! }
      .to raise_error(Redis::CommandError, "temporary Redis failure")

    expect(REDIS).not_to have_received(:multi)
    expect(REDIS).not_to have_received(:scan_each)
    expect(REDIS).not_to have_received(:del)
      .with("slack:public_channel:old")
    expect(REDIS).not_to have_received(:rename)
  end
end
