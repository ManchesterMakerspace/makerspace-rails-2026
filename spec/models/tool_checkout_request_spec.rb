require "rails_helper"

RSpec.describe ToolCheckoutRequest do
  describe "#notify_requestor" do
    let(:member) { create(:member, :current, status: "suspended") }
    let(:request) { ToolCheckoutRequest.create!(member: member, tool: create(:tool)) }

    before do
      SlackUser.create!(member: member, slack_id: "U123", slack_email: member.email)
    end

    it "does not directly notify a member whose notifications are suppressed" do
      expect(Service::SlackConnector).not_to receive(:send_slack_message)

      request.notify_requestor
    end
  end
end
