class Admin::Members::TotpController < AdminController
  before_action :set_member

  # DELETE /api/admin/members/:member_id/totp
  # Admin resets a member's TOTP and immediately invalidates their sessions.
  def destroy
    raise ::Error::Forbidden.new if @member.id == current_member.id

    @member.update!(
      otp_secret_encrypted:   nil,
      otp_required_for_login: false,
      otp_enabled_at:         nil,
      session_token:          SecureRandom.hex(32)  # rotate token to invalidate sessions
    )

    render json: { message: "TOTP reset for #{@member.fullname}." }, status: :ok
  end

  private

  def set_member
    @member = Member.find(params[:member_id])
    raise ::Mongoid::Errors::DocumentNotFound.new(Member, { id: params[:member_id] }) if @member.nil?
  end
end
