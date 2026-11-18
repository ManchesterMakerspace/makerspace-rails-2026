# Keep provider calls and nondurable work outside retryable accounting writes.
module MembershipPaidDeferredEffects
  def defer_paid_membership_effect(&effect)
    return false unless MembershipPaidCredit.active?
    MembershipPaidCredit.after_commit(&effect)
    true
  end
end
