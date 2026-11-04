class Admin::SlackIdentityConflictsController < AdminController
  # GET /api/admin/slack_identity_conflicts
  # live_check is "fresh" (a scan of Slack just finished), "cached" (a scan from the
  # last few minutes), "scanning" (a scan is under way: conflicts holds what it has
  # found so far plus the saved ones, progress says how far it has got, and the page
  # asks again until it is done) or "unavailable" (the scan failed repeatedly, so only
  # conflicts saved earlier are listed).
  def index
    conflicts, live_check = Service::SlackUserSync.detect_conflicts_for_page
    body = { conflicts: conflicts, live_check: live_check, scan_size: SystemConfig.slack_conflict_scan_size }
    body[:progress] = Service::SlackUserSync.live_scan_progress if live_check == :scanning
    render json: body
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
