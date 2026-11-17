class Members::ContinuousPaidMembershipsController < AuthenticationController
  def show
    unless params[:id].to_s == current_member.id.to_s || is_admin? || is_board_member?
      raise Error::Forbidden.new
    end
    render json: MembershipPaidCredit.read(params[:id])
  end
end
