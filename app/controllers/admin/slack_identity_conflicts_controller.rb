class Admin::SlackIdentityConflictsController < AdminController
  # GET /api/admin/slack_identity_conflicts
  # live_check is "fresh" (Slack was just scanned), "cached" (a scan from the last
  # few minutes), or "unavailable" (the scan could not finish, so only conflicts
  # saved earlier are listed).
  def index
    conflicts, live_check = Service::SlackUserSync.detect_conflicts_for_page
    render json: { conflicts: conflicts, live_check: live_check }
  end

  # POST /api/admin/slack_identity_conflicts/reassign
  def reassign
    params.require([:slack_id, :member_id])
    member = Service::SlackUserSync.reassign_identity(
      slack_id: params[:slack_id],
      member_id: params[:member_id],
      actor: current_member
    )
    Service::SlackUserSync.clear_live_conflicts_cache
    render json: { message: "#{params[:slack_id]} linked to #{member.fullname}", member_id: member.id.to_s }, status: :ok
  end

  # POST /api/admin/slack_identity_conflicts/dismiss
  def dismiss
    params.require([:slack_id, :member_id])
    member = Service::SlackUserSync.dismiss_conflict(
      slack_id: params[:slack_id],
      member_id: params[:member_id],
      slack_email: params[:slack_email],
      slack_name: params[:slack_name],
      actor: current_member
    )
    Service::SlackUserSync.clear_live_conflicts_cache
    render json: { message: "#{params[:slack_id]} dismissed for #{member.fullname}", member_id: member.id.to_s }, status: :ok
  end
end
