require "rails_helper"

RSpec.describe SlackMessagesJob, type: :job do
  let(:payloads) do
    [
      {
        "message" => "Message 1",
        "channel" => "C1",
        "timestamp" => "2026-01-01T00:00:02Z",
        "dedupe_key" => "request.one"
      },
      {
        "message" => "Message 2",
        "channel" => "C1",
        "timestamp" => "2026-01-01T00:00:01Z",
        "dedupe_key" => "request.two"
      },
      {
        "message" => "duplicate",
        "channel" => "C1",
        "timestamp" => "2026-01-01T00:00:03Z",
        "dedupe_key" => "request.two"
      }
    ]
  end

  it "groups, orders, and deduplicates payloads without Redis scratch keys" do
    expect_any_instance_of(described_class)
      .to receive(:send_slack_messages)
      .with(["Message 2", "Message 1"], "C1")

    described_class.perform_now(payloads)
  end

  it "uses the slack queue" do
    expect(described_class.queue_name).to eq("slack")
  end
end
