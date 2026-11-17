class Admin::Members::ContinuousPaidMembershipsController < AdminController
  def update
    # AdminController also accepts Board. This correction is explicitly Admin only.
    raise Error::Forbidden.new unless is_admin?
    render json: MembershipPaidCredit.increase!(member_id: params[:id],
      months: params[:continuous_paid_membership_months], expected_revision: params[:expected_revision],
      reason: params[:reason], actor: current_member)
  end
end
