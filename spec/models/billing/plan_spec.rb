require 'rails_helper'

RSpec.describe BraintreeService::Plan, type: :model do
  let(:gateway) { double } # Create a fake gateway
  let(:fake_plan) { double(id: "foo") }

  it "has a factory" do
    expect(build(:plan)).to be_truthy
  end

  context "public methods" do
    describe "#get_plans" do
      it "fetches all plans" do 
        allow(gateway).to receive_message_chain(:plan, :all, map: [fake_plan])
        expect(BraintreeService::Plan.get_plans(gateway)).to eq([fake_plan])
      end
    end

    it "selects plans by their ID for each requested type", :aggregate_failures do
      membership_plan = double(id: "monthly_membership")
      rental_plan = double(id: "monthly_rental")
      other_plan = double(id: "other_plan")
      plans = [membership_plan, rental_plan, other_plan]

      expect(described_class.select_plans_for_types(["member"], plans)).to eq([membership_plan])
      expect(described_class.select_plans_for_types(["rental"], plans)).to eq([rental_plan])
      expect(described_class.select_plans_for_types(["foo"], plans)).to eq([])
    end
  end
end
