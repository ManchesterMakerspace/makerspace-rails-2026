require 'rails_helper'

#https://github.com/mongoid/mongoid-rspec

RSpec.describe EarnedMembership::ReportRequirement, type: :model do

  describe "public methods" do
    it "updates term count" do
    end
  end

  describe "private methods" do
    it "validates requirement exists" do
      travel_to(Time.now) do
        report = build(:report)
        report_requirement = build(:report_requirement_with_term, requirement: nil, report: report)
        expect(report_requirement.valid?).to be(false)
        report.save
        expect(report_requirement.persisted?).to be(false)

        report_requirement.requirement = create(:requirement)
        # Assign the requirement's current term so no_future_reporting passes
        report_requirement.term = report_requirement.requirement.current_term
        expect(report_requirement.valid?).to be(true)
        report.save
        expect(report_requirement.persisted?).to be(true)
      end
    end

    it "validates term exists" do
      # around not available at example level — use ensure to guarantee restoration
      # even if an assertion raises before the final set_callback.
      begin
        EarnedMembership::Report.skip_callback(:validation, :before, :apply_term)
        travel_to(Time.now) do
          report = build(:report)
          requirement = create(:requirement, term_length: 1)
          report_requirement = build(:report_requirement, report: report, requirement: requirement)
          expect(report_requirement.valid?).to be(false)
          report.save
          expect(report_requirement.persisted?).to be(false)

          report_requirement.term = requirement.current_term
          expect(report_requirement.valid?).to be(true)
          report.save
          expect(report_requirement.persisted?).to be(true)
        end
      ensure
        EarnedMembership::Report.set_callback(:validation, :before, :apply_term)
      end
    end
  end
end