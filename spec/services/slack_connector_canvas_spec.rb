require "rails_helper"

RSpec.describe Service::SlackConnector do
  let(:client) { double("Slack client") }

  before do
    allow(described_class).to receive(:client).and_return(client)
  end

  it "creates an unbound canvas and grants a shop channel read access" do
    allow(client).to receive(:canvases_create)
      .with(title: "Today's Reservations")
      .and_return(double(canvas_id: "F123"))
    expect(client).to receive(:canvases_access_set).with(
      canvas_id: "F123",
      access_level: "read",
      channel_ids: ["C123"]
    )

    canvas_id = described_class.create_canvas("Today's Reservations")
    described_class.set_canvas_channel_access(canvas_id, "C123")

    expect(canvas_id).to eq("F123")
  end

  it "replaces the entire canvas with the rendered agenda" do
    expect(client).to receive(:canvases_edit).with(
      canvas_id: "F123",
      changes: [
        {
          operation: "replace",
          document_content: {
            type: "markdown",
            markdown: "# Woodshop Reservations"
          }
        }
      ]
    )

    described_class.replace_canvas("F123", "# Woodshop Reservations")
  end

  it "resolves a configured channel name to its Slack channel ID" do
    channel = double(name: "woodshop", id: "C123")
    response = double(
      channels: [channel],
      response_metadata: double(next_cursor: "")
    )
    expect(client).to receive(:conversations_list).with(
      types: "public_channel,private_channel",
      exclude_archived: true,
      limit: 200,
      cursor: nil
    ).and_return(response)

    expect(described_class.find_channel_id("#woodshop")).to eq("C123")
  end
end
