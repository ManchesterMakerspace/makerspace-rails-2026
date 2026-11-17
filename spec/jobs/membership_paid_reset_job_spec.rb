require 'rails_helper'

RSpec.describe MembershipPaidResetJob do
  it 'executes the conditional reset sweep synchronously' do
    expect(MembershipPaidCredit).to receive(:sweep!).once
    described_class.perform_now
    expect(File.read(Rails.root.join('config/schedule.rb'))).to include("runner 'MembershipPaidResetJob.perform_now'")
  end
end
