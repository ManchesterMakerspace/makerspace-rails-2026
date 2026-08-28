require "rails_helper"

RSpec.describe Service::Analytics do
  describe Service::Analytics::Members do
    let(:january_end) { Date.new(2024, 1, 31).to_time }

    before do
      Member.collection.insert_many([
        { status: "activeMember", firstname: "Exact", lastname: "Start", startDate: january_end, expirationTime: january_end.to_i * 1000 },
        { status: "pending", firstname: "Exact", lastname: "Expiry", startDate: january_end - 1.month, expirationTime: january_end.to_i * 1000 },
        { status: "activeMember", firstname: "Too", lastname: "Early", startDate: january_end - 1.month, expirationTime: (january_end.to_i * 1000) - 1 },
        { status: "activeMember", firstname: "Too", lastname: "Late", startDate: january_end + 1.second, expirationTime: january_end.to_i * 1000 },
        { status: "inactive", firstname: "Wrong", lastname: "Status", startDate: january_end - 1.month, expirationTime: january_end.to_i * 1000 }
      ])
    end

    it "includes members starting or expiring exactly at month end and zero-fills empty months" do
      expect(described_class.active_members_by_month(
        start_date: Date.new(2024, 1, 1), end_date: Date.new(2024, 2, 29)
      )).to eq([
        { date: "2024-01", count: 2 },
        { date: "2024-02", count: 0 }
      ])
    end

    it "preserves the legacy date-and-count pair return shape" do
      expect(described_class.get_membership_per_month(
        Mongoid::Criteria.new(Member), Date.new(2024, 1, 1)
      ).first).to eq([Date.new(2024, 1, 1), 2])
    end
  end

  describe Service::Analytics::Invoices do
    before do
      Invoice.collection.insert_many([
        { plan_id: "membership-one-month-recurring", amount: 25.0, settled_at: Time.current },
        { plan_id: "membership-one-month-recurring", discount_id: "monthly_membership_sso", amount: 10.0, settled_at: Time.current },
        { plan_id: "membership-one-month-recurring", discount_id: "other-discount", amount: nil, settled_at: Time.current },
        { plan_id: "membership-one-month-recurring", amount: 99.0, settled_at: nil },
        { plan_id: "rental-quarterly-recurring-locker-subscription", amount: nil, settled_at: Time.current }
      ])
    end

    it "aggregates settled regular and discounted memberships, including nil amounts" do
      expect(described_class.get_membership_subscription_count).to include(
        "Monthly" => 1, "Monthly (Discounted)" => 2
      )
      expect(described_class.get_membership_subscription_dollars).to include(
        "Monthly" => 25.0, "Monthly (Discounted)" => 10.0
      )
    end

    it "returns zero-filled rental reports" do
      expect(described_class.get_rental_count).to eq("Shelf" => 0, "Locker" => 1, "Plot" => 0)
      expect(described_class.get_rental_dollars).to eq("Shelf" => 0.0, "Locker" => 0.0, "Plot" => 0.0)
    end
  end

  describe Service::Analytics::Payments do
    before do
      Payment.collection.insert_many([
        { product: "1-MONTH SUBSCRIPTION", amount: 20.0, status: "Completed" },
        { product: "Plot 1-month Subscription", amount: 30.0, status: "Completed" },
        { product: "locker monthly", amount: nil, status: "Completed" },
        { product: "Tip jar", amount: 4.0, status: "Completed" },
        { product: nil, amount: 2.0, status: "Completed" },
        { product: "5-donation", amount: 5.0, status: "Pending" }
      ])
    end

    it "classifies case-insensitively and gives membership precedence for overlapping products" do
      expect(described_class.get_membership_subscription_count).to include("Monthly" => 2)
      expect(described_class.get_rental_count).to eq("Plot" => 0, "Shelf" => 0, "Locker" => 1)
    end

    it "sums nil amounts as zero and applies completed status to every report" do
      expect(described_class.get_rental_dollars).to eq("Plot" => 0.0, "Shelf" => 0.0, "Locker" => 0.0)
      expect(described_class.get_donation_count.values.sum).to eq(0)
    end

    it "finds uncategorized completed products without collecting ids" do
      expect(described_class.not_categorized).to contain_exactly("Tip jar", nil)
    end
  end
end
