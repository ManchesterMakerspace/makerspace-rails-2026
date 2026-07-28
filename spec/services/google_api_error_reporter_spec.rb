require "rails_helper"

RSpec.describe Service::GoogleApiErrorReporter do
  FakePermissionError = Class.new(StandardError) do
    attr_reader :status_code, :body, :response_header

    def initialize
      super("PERMISSION_DENIED: caller lacks calendar ownership")
      @status_code = 403
      @body = '{"error":{"status":"PERMISSION_DENIED","message":"Owner access required"}}'
      @response_header = { "x-request-id" => "google-request-123" }
    end
  end

  it "persists and alerts with the complete Google permission error" do
    error = FakePermissionError.new
    allow(Service::AuditLogger).to receive(:log)
    allow(Service::SlackConnector).to receive(:send_slack_message)

    described_class.report_if_permission_denied(
      error,
      operation: "calendar.labels.ensure",
      resource_type: "Shop",
      resource_id: BSON::ObjectId.new
    )

    expect(Service::AuditLogger).to have_received(:log).with(
      hash_including(
        event_type: "google_api_permission_denied",
        after_snapshot: hash_including(
          error_message: include(
            "caller lacks calendar ownership",
            "Owner access required",
            "google-request-123"
          )
        )
      )
    )
    expect(Service::SlackConnector).to have_received(:send_slack_message).with(
      include("caller lacks calendar ownership", "Owner access required", "google-request-123"),
      anything
    )
  end
end
