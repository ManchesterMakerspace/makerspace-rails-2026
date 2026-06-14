class SessionsController < Devise::SessionsController
  # POST /api/members/sign_in
  def create
    resource = warden.authenticate!(:scope => resource_name, :recall => "#{controller_path}#new")

    # Explicitly check active_for_authentication? — warden.authenticate! with :recall
    # does not raise on inactive members, it just calls the recall action and continues.
    # Without this check, revoked/suspended members can still complete sign-in.
    unless resource&.active_for_authentication?
      message = resource ? I18n.t("devise.failure.#{resource.inactive_message}") : I18n.t('devise.failure.invalid', authentication_keys: 'email')
      render json: { message: message }, status: :unauthorized and return
    end

    # Check if TOTP is enrolled — require code entry before issuing full session
    if resource.otp_required_for_login? && resource.otp_secret_encrypted.present?
      session[:totp_pending_member_id]      = resource.id.to_s
      session[:totp_pending_expires_at]     = 10.minutes.from_now.to_i
      render json: { totp_required: true }, status: :accepted and return
    end

    # Check if TOTP enrollment is required for this member's role but not yet set up
    if totp_enrollment_required?(resource) && !resource.otp_required_for_login?
      sign_in(resource_name, resource)
      member_json = ActiveModelSerializers::SerializableResource.new(
        resource,
        serializer: MemberSerializer,
        adapter: :attributes
      ).as_json
      render json: member_json.merge(totp_enrollment_required: true) and return
    end

    sign_in(resource_name, resource)
    render json: resource, adapter: :attributes and return
  end

  private

  def totp_enrollment_required?(member)
    case member.role
    when 'admin'            then SystemConfig.enabled?('require_totp_admin')
    when 'board_member'     then SystemConfig.enabled?('require_totp_board')
    when 'resource_manager' then SystemConfig.enabled?('require_totp_rm')
    else false
    end
  end
end