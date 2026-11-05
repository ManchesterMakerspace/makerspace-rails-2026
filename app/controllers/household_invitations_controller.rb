# Public: the link page can say who invited them before they sign in. It reveals nothing about the household beyond the
# inviter's first name and last initial, the invited email and when the invitation expires.
class HouseholdInvitationsController < ApplicationController
  # POST /api/household_invitations/lookup { token }
  def lookup
    params.require(:token)
    info = HouseholdInvitations.public_info(params[:token])
    raise ::Error::NotFound.new unless info

    render json: info, status: :ok
  end
end
