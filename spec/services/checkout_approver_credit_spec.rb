require "rails_helper"

RSpec.describe CheckoutApproverCredit do
  let(:shop) { create(:shop) }
  let(:tool) { create(:tool, shop: shop) }
  let(:member) { create(:member, :current) }
  let(:approver) { create(:member, :current) }

  it "silently awards 0.25 approved credits to an additional approver" do
    CheckoutApprover.create!(member: approver, tool_ids: [tool.id.to_s])
    checkout = create(:tool_checkout, member: member, tool: tool, approved_by: approver)
    expect(Service::SlackConnector).not_to receive(:send_slack_message)

    credit = described_class.award!(checkout)

    expect(credit).to have_attributes(member_id: approver.id, issued_by_id: approver.id,
      credit_value: 0.25, status: "approved")
    expect(checkout.reload.volunteer_credit_id).to eq(credit.id)
  end

  it "does not award RMs, board members, admins, or unassigned members" do
    actors = [
      create(:member, :current),
      create(:member, :current, :admin),
      create(:member, :current, :board_member),
      create(:member, :current, :resource_manager, resource_manager_shop_ids: [shop.id.to_s])
    ]

    actors.each do |actor|
      checkout = create(:tool_checkout, member: member, tool: tool, approved_by: actor)
      expect(described_class.award!(checkout)).to be_nil
    end
    expect(VolunteerCredit.count).to eq(0)
  end

  it "silently offsets the credit when the checkout is revoked" do
    CheckoutApprover.create!(member: approver, tool_ids: [tool.id.to_s])
    checkout = create(:tool_checkout, member: member, tool: tool, approved_by: approver)
    credit = described_class.award!(checkout)
    expect(Service::SlackConnector).not_to receive(:send_slack_message)

    checkout.update!(revoked_at: Time.current)

    reversal = VolunteerCredit.find_by(reversal_of_id: credit.id)
    expect(reversal).to have_attributes(member_id: approver.id, credit_value: -0.25, status: "reversal")
    expect(credit.reload).to be_reversed
  end

  it "preserves treasurer review for a reversed credit that funded a discount" do
    CheckoutApprover.create!(member: approver, tool_ids: [tool.id.to_s])
    checkout = create(:tool_checkout, member: member, tool: tool, approved_by: approver)
    credit = described_class.award!(checkout)
    credit.update!(discount_applied: true, discount_applied_at: Time.current)
    expect_any_instance_of(VolunteerCredit).to receive(:notify_braintree_review_needed)
      .with(approver, "Tool checkout revoked")

    described_class.reverse!(checkout)
  end
end
