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
end
