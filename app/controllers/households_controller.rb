# A household's primary invites a second adult, who joins by link. See HouseholdInvitations for the rules.
class HouseholdsController < AuthenticationController
  # GET /api/household
  def show
    render json: HouseholdInvitations.state_for(current_member), status: :ok
  end

  # POST /api/household/invitations { email }
  def invite
    params.require(:email)
    invitation = HouseholdInvitations.invite!(primary: current_member, email: params[:email])
    render json: HouseholdInvitations.state_for(current_member).merge(invitation_id: invitation.id.to_s), status: :created
  end

  # POST /api/household/invitations/:id/resend
  def resend
    HouseholdInvitations.resend!(find_invitation, primary: current_member)
    render json: HouseholdInvitations.state_for(current_member), status: :ok
  end

  # DELETE /api/household/invitations/:id
  def revoke
    HouseholdInvitations.revoke!(find_invitation, primary: current_member)
    render json: HouseholdInvitations.state_for(current_member), status: :ok
  end

  # POST /api/household/invitations/preview { token }  (a body, not a query string, so the token is not logged)
  def preview
    params.require(:token)
    render json: HouseholdInvitations.preview(member: current_member, token: params[:token]), status: :ok
  end

  # POST /api/household/invitations/accept { token }
  def accept
    params.require(:token)
    HouseholdInvitations.accept!(member: current_member, token: params[:token])
    render json: HouseholdInvitations.state_for(current_member.reload), status: :ok
  end

  private

  def find_invitation
    HouseholdInvitation.where(id: params[:id]).first || raise(::Error::NotFound.new)
  end
end
