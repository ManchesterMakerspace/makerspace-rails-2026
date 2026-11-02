module Service
  module MemberAccess
    # Revoke Google Drive and Slack access for a member.
    # Safe to call from rake tasks, subscribers, or controllers.
    #
    # alert: false skips the channel-wide "must be removed by hand" alert when a removal fails. The
    # caller then reads the returned statuses instead (the soft delete shows them to the admin).
    def self.revoke(member, alert: true)
      results = {}
      results[:gdrive_resources]      = revoke_gdrive_folder(member, ENV['RESOURCES_FOLDER'],      'Resources (reader)', alert: alert)
      results[:gdrive_transfer_share] = revoke_gdrive_folder(member, ENV['GOOGLE_TRANSFER_SHARE'], 'Transfer Share (writer)', alert: alert)
      results[:slack]                 = revoke_slack_access(member, alert: alert)
      results
    end

    # Full teardown of a member's access: cancel any live Braintree
    # subscription, revoke Drive/Slack (see #revoke above), silence outgoing
    # email/Slack notifications, and rotate the session token to invalidate
    # any active portal sessions. Used both when a member's status is set to
    # revoked and when an account is soft-deleted (see Service::MemberSoftDelete)
    # -- kept as one method so the two flows can't quietly drift apart.
    #
    # Returns the per-step results (the revoke statuses plus :subscription when one was cancelled).
    def self.full_deprovision(member, alert: true)
      results = {}

      if member.subscription_id
        begin
          ::BraintreeService::Subscription.cancel(::Service::BraintreeGateway.connect_gateway, member.subscription_id)
          results[:subscription] = { status: :ok }
        rescue => e
          ::Service::SlackConnector.send_slack_message(
            "⚠️ Error cancelling subscription for #{member.fullname}: #{e.message}",
            ::Service::SlackConnector.logs_channel
          )
          results[:subscription] = { status: :error, message: e.message }
        end
      end

      begin
        results.merge!(revoke(member, alert: alert) || {})
      rescue => e
        ::Service::SlackConnector.send_slack_message(
          "⚠️ Error revoking Drive/Slack access for #{member.fullname}: #{e.message}",
          ::Service::SlackConnector.logs_channel
        )
        results[:revoke] = { status: :error, message: e.message }
      end

      member.update_attribute(:silence_emails, true)
      member.update_attribute(:session_token, SecureRandom.hex)
      results
    end

    # ── Google Drive ──────────────────────────────────────────────────────────

    def self.revoke_gdrive_folder(member, folder_id, label, alert: true)
      return { status: :skipped, reason: "#{label} folder env var not configured" } if folder_id.blank?
      return { status: :skipped, reason: 'GDRIVE_INVITES_ENABLED is not true' } unless ENV['GDRIVE_INVITES_ENABLED'] == 'true'

      email = member.email
      # A share made before the member changed their email address is still under the old one.
      emails = [member.email, member.google_previous_email].map { |address| address.to_s.downcase.strip }.reject(&:blank?).uniq

      begin
        drive       = Service::GoogleDrive.load_gdrive
        permissions = drive.list_permissions(folder_id, fields: 'permissions(id,emailAddress,role)', supports_all_drives: true)
        matches     = permissions.permissions.select { |p| emails.include?(p.email_address&.downcase) }

        if matches.any?
          matches.each { |perm| drive.delete_permission(folder_id, perm.id, supports_all_drives: true) }
          { status: :ok, message: "Removed #{matches.map(&:role).join(', ')} permission from #{label}" }
        else
          { status: :not_found, message: "No permission found for #{email} on #{label}" }
        end
      rescue => e
        alert_manual_gdrive_revocation_required(member, label, e.message) if alert
        { status: :error, message: e.message }
      end
    end

    # ── Slack ─────────────────────────────────────────────────────────────────

    def self.revoke_slack_access(member, alert: true)
      slack_id = member.slack_user&.slack_id

      admin_client = ::Service::SlackConnector.admin_client(
        "users.admin.setInactive"
      )
      unless admin_client
        reason = 'SLACK_ADMIN_TOKEN not configured'
        alert_manual_slack_revocation_required(member, slack_id, reason) if alert
        return { status: :skipped, reason: reason }
      end

      begin
        lookup_client = ::Service::SlackConnector.client
        user = lookup_client.users_lookupByEmail(email: member.email)
        slack_id = user.user.id
        admin_client.users_admin_setInactive(user: slack_id)
        { status: :ok, message: "Deactivated Slack user for #{member.email}" }
      rescue Slack::Web::Api::Errors::UsersNotFound
        revoke_stored_slack_id(admin_client, member, slack_id, alert: alert)
      rescue => e
        alert_manual_slack_revocation_required(member, slack_id, e.message) if alert
        { status: :error, message: e.message }
      end
    end


    def self.revoke_stored_slack_id(client, member, slack_id, alert: true)
      unless slack_id.present?
        return { status: :not_found, message: "No Slack user found for #{member.email}" }
      end

      client.users_admin_setInactive(user: slack_id)
      { status: :ok, message: "Deactivated stored Slack user #{slack_id} for #{member.email}" }
    rescue => e
      alert_manual_slack_revocation_required(member, slack_id, e.message) if alert
      { status: :error, message: e.message }
    end

    def self.alert_manual_slack_revocation_required(member, slack_id, reason)
      message = "<!channel> :rotating_light: Automatic Slack revocation failed for revoked or deleted member #{member.fullname} " \
                "(Slack ID: #{slack_id.presence || 'unknown'}). This member must be manually disabled by an admin. " \
                "Reason: #{reason}"

      response = ::Service::SlackConnector.send_slack_message(message, ::Service::SlackConnector.admin_channel)
      ts = response.respond_to?(:ts) ? response.ts : response.try(:[], 'ts') || response.try(:[], :ts)
      ::Service::SlackConnector.pin_slack_message(::Service::SlackConnector.admin_channel, ts)
    rescue => e
      Rails.logger.error("Failed to send/pin manual Slack revocation alert for #{member.fullname}: #{e.message}")
    end

    def self.alert_manual_gdrive_revocation_required(member, label, reason)
      message = "<!channel> :rotating_light: Automatic Google Drive revocation failed for revoked or deleted member #{member.fullname} " \
                "(#{label}). This member must be manually removed by an admin. " \
                "Reason: #{reason}"

      response = ::Service::SlackConnector.send_slack_message(message, ::Service::SlackConnector.admin_channel)
      ts = response.respond_to?(:ts) ? response.ts : response.try(:[], 'ts') || response.try(:[], :ts)
      ::Service::SlackConnector.pin_slack_message(::Service::SlackConnector.admin_channel, ts)
      Honeybadger.notify(
        "Automatic Google Drive revocation failed for #{member.fullname}",
        context: { member_id: member.id.to_s, member_email: member.email, label: label, reason: reason }
      ) if defined?(Honeybadger)
    rescue => e
      Rails.logger.error("Failed to send/pin manual Google Drive revocation alert for #{member.fullname}: #{e.message}")
    end
  end
end
