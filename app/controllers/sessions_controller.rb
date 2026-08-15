class SessionsController < Devise::SessionsController
  # Devise controllers don't inherit from ApplicationController, so without
  # this, Current.ip_address is never set here — and the naive fix
  # (reading request.ip/request.remote_ip directly) would be actively
  # wrong: this app has no Rails trusted_proxies configured, it relies on
  # this concern reading the CF-Connecting-IP/True-Client-IP headers
  # directly, so request.ip alone would log Cloudflare's edge IP instead
  # of the real caller on every request.
  include SetCurrentRequestDetails

  # POST /api/members/sign_in
  def create
    resource = warden.authenticate!(:scope => resource_name, :recall => "#{controller_path}#new")

    # Explicitly check active_for_authentication? — warden.authenticate! with :recall
    # does not raise on inactive members, it just calls the recall action and continues.
    # Without this check, revoked/suspended members can still complete sign-in.
    # active_for_authentication? is protected in Devise so we use send.
    unless resource&.send(:active_for_authentication?)
      if resource
        message = I18n.t("devise.failure.#{resource.send(:inactive_message)}")
        block_reason = resource.status
        # Security audit — log and notify on blocked login attempts
        Rails.logger.warn("[Security] Blocked login attempt for #{block_reason} member: #{resource.email}")
        # NOTE: previously AuditLog.create! with a bare `description:` field
        # that doesn't exist on AuditLog, plus missing required fields
        # (log_type/resource_type/resource_id/slack_message) — the `rescue
        # nil` was silently swallowing a validation failure on every call,
        # so this entry was never actually being persisted. Replaced with
        # Service::AuditLogger.log, which fills in the required fields and
        # doesn't raise on failure (it notifies Honeybadger internally).
        Service::AuditLogger.log(
          log_type:        'member',
          event_type:      'blocked_login_attempt',
          resource_type:   'Member',
          resource_id:     resource.id,
          actor:           resource,
          subject:         resource,
          message_details: "Login blocked — member status: #{block_reason}",
          slack_channel:   ::Service::SlackConnector.logs_channel
        )
        ::Service::SlackConnector.send_slack_message(
          "🚫 #{block_reason.capitalize} member #{resource.fullname} (#{resource.email}) attempted portal login",
          ::Service::SlackConnector.logs_channel
        ) rescue nil
      else
        message = I18n.t('devise.failure.invalid', authentication_keys: 'email')
      end
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