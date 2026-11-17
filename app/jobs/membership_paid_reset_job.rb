class MembershipPaidResetJob < ApplicationJob
  def perform
    MembershipPaidCredit.sweep!
  end
end
