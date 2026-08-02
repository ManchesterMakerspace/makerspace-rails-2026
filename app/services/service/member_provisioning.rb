require 'set'

module Service
  module MemberProvisioning
    extend self

    SLACK_MANUAL_ACTIONS = %w[invite promotion].freeze
    ADEQUATE_READER_ROLES = %w[reader commenter writer fileOrganizer organizer owner].freeze
    ADEQUATE_WRITER_ROLES = %w[writer fileOrganizer organizer owner].freeze

    def initialize_tracking(member)
      email = normalize_email(member.email)
      return if member.provisioning_initialized_at.present? &&
        member.provisioning_email.to_s == email

      member.set(
        provisioning_initialized_at: Time.current,
        provisioning_email: email,
        slack_invite_confirmed_at: nil,
        slack_invite_source: nil,
        slack_invite_mode: nil,
        slack_acceptance_pending: nil,
        slack_joined_at: nil,
        slack_full_member_at: nil,
        slack_manual_action_required: nil,
        slack_last_attempt_at: nil,
        slack_last_error: nil,
        google_resources_access_confirmed_at: nil,
        google_transfer_access_confirmed_at: nil,
        google_last_attempt_at: nil,
        google_last_error: nil
      )
    end

    def invite_slack(member, raise_errors: false)
      initialize_tracking(member)
      ensure_slack_invite_allowed!(member)

      if matching_slack_user(member)
        confirm_slack_invite(member, source: 'slack_user_record')
        return { status: :confirmed, source: :slack_user_record }
      end

      member.set(slack_last_attempt_at: Time.current, slack_last_error: nil)
      response = ::Service::SlackConnector.invite_to_slack(
        member.email,
        member.lastname,
        member.firstname
      )
      mode = ::Service::SlackConnector.new_signup_invite_mode
      confirm_slack_invite(member, source: 'api', mode: mode)
      audit(member, 'slack_invite_succeeded', "Slack #{mode.humanize.downcase} invite accepted by the API")
      { status: :invited, response: response, mode: mode }
    rescue => error
      member.set(slack_last_attempt_at: Time.current, slack_last_error: error_message(error))
      if ENV['SLACK_INVITES_ENABLED'] == 'true'
        mark_manual_action(member, 'invite', error)
      end
      raise error if raise_errors
      { status: :error, error: error }
    end

    def provision(member)
      initialize_tracking(member)
      confirm_slack_invite(member, source: 'slack_user_record') if matching_slack_user(member)
      return { status: :ineligible } unless member.provisioning_eligible?

      google_result = if ENV['GDRIVE_INVITES_ENABLED'] == 'true'
        provision_google(member)
      else
        { status: :skipped }
      end
      slack_result = reconcile_slack_member(member)
      { status: :processed, google: google_result, slack: slack_result }
    end

    def provision_google(member, raise_errors: false)
      initialize_tracking(member)
      ensure_google_provisioning_allowed!(member)
      member.set(google_last_attempt_at: Time.current, google_last_error: nil)

      results = {}
      results[:resources] = ensure_google_permission(
        member,
        field: :google_resources_access_confirmed_at,
        folder_id: ENV['RESOURCES_FOLDER'],
        role: 'reader',
        adequate_roles: ADEQUATE_READER_ROLES,
        label: 'Member Resources'
      )
      results[:transfer] = ensure_google_permission(
        member,
        field: :google_transfer_access_confirmed_at,
        folder_id: ENV['GOOGLE_TRANSFER_SHARE'],
        role: 'writer',
        adequate_roles: ADEQUATE_WRITER_ROLES,
        label: 'Google Transfer Share'
      )

      member.set(google_last_error: nil)
      results
    rescue => error
      member.set(google_last_attempt_at: Time.current, google_last_error: error_message(error))
      audit_failure(member, 'google_drive_provisioning_failed', error)
      raise error if raise_errors
      { status: :error, error: error }
    end

    def reconcile_slack_member(member, live_user = nil, promote: true, lookup: true)
      initialize_tracking(member)
      confirm_slack_invite(member, source: 'slack_user_record') if matching_slack_user(member)
      return { status: :blocked } if blocked_status?(member)

      live_user = lookup_slack_user(member.email) if live_user.nil? && lookup
      return { status: :not_found } if live_user.nil?
      return { status: :email_mismatch } unless live_user_email(live_user) == normalize_email(member.email)

      confirm_slack_invite(
        member,
        source: member.slack_invite_source.presence || 'slack_user_record'
      )
      if slack_value(live_user, 'is_invited_user') == true
        member.set(slack_acceptance_pending: true)
        return { status: :invite_pending }
      end

      now = Time.current
      member.set(
        slack_acceptance_pending: false,
        slack_joined_at: member.slack_joined_at || now
      )
      ensure_slack_user_record(member, live_user)

      guest = slack_value(live_user, 'is_ultra_restricted') == true ||
        slack_value(live_user, 'is_restricted') == true
      unless guest
        member.set(
          slack_invite_mode: member.slack_invite_mode.presence || 'full_member',
          slack_full_member_at: member.slack_full_member_at || now,
          slack_manual_action_required: nil,
          slack_last_error: nil
        )
        return { status: :full_member }
      end

      member.set(slack_invite_mode: 'single_channel_guest')
      return { status: :guest } unless member.provisioning_eligible?
      return { status: :guest, promotion: :deferred } unless promote

      promote_slack_member(member, slack_value(live_user, 'id'))
    end

    def promote_slack_member(member, slack_id)
      raise Error::NotAllowed.new('Slack user ID is unavailable') if slack_id.blank?

      member.set(slack_last_attempt_at: Time.current, slack_last_error: nil)
      ::Service::SlackConnector.promote_to_regular(slack_id)
      member.set(
        slack_full_member_at: Time.current,
        slack_manual_action_required: nil,
        slack_last_error: nil
      )
      audit(member, 'slack_promotion_succeeded', 'Slack guest promoted to a full member')
      { status: :full_member }
    rescue => error
      member.set(slack_last_attempt_at: Time.current, slack_last_error: error_message(error))
      mark_manual_action(member, 'promotion', error)
      { status: :manual_promotion_required, error: error }
    end

    def reconcile_all!
      live_users = slack_users_by_email
      Member.where(:provisioning_initialized_at.ne => nil).each do |member|
        begin
          local_record = matching_slack_user(member)
          confirm_slack_invite(member, source: 'slack_user_record') if local_record
          reconcile_slack_member(
            member,
            live_users[normalize_email(member.email)],
            lookup: false
          )
          if ENV['GDRIVE_INVITES_ENABLED'] == 'true' &&
              member.provisioning_eligible? &&
              !google_complete?(member)
            provision_google(member)
          end
        rescue => error
          Rails.logger.error(
            "[MemberProvisioning] reconciliation failed member_id=#{member.id}: #{error_message(error)}"
          )
          Honeybadger.notify(error, context: { member_id: member.id.to_s }) if defined?(Honeybadger)
        end
      end
    end

    # Reads existing remote state and writes only local confirmation fields.
    # It never sends an invite, creates a Drive permission, or promotes a user.
    def backfill!
      live_users = slack_users_by_email
      local_slack_emails = SlackUser.all.each_with_object({}) do |slack_user, memo|
        email = normalize_email(slack_user.slack_email)
        memo[email] = slack_user if email.present?
      end
      resources_emails = google_permission_emails(ENV['RESOURCES_FOLDER'], ADEQUATE_READER_ROLES)
      transfer_emails = google_permission_emails(ENV['GOOGLE_TRANSFER_SHARE'], ADEQUATE_WRITER_ROLES)

      counts = Hash.new(0)
      Member.all.each do |member|
        initialize_tracking(member)
        email = normalize_email(member.email)

        if local_slack_emails[email]
          local_slack_emails[email].set(member_id: member.id)
          confirm_slack_invite(member, source: 'slack_user_record')
          counts[:slack_invited] += 1
        end
        if live_users[email]
          reconcile_slack_member(member, live_users[email], promote: false, lookup: false)
          counts[:slack_live] += 1
        end
        if resources_emails.include?(email)
          member.set(google_resources_access_confirmed_at: member.google_resources_access_confirmed_at || Time.current)
          counts[:google_resources] += 1
        end
        if transfer_emails.include?(email)
          member.set(google_transfer_access_confirmed_at: member.google_transfer_access_confirmed_at || Time.current)
          counts[:google_transfer] += 1
        end
      end
      counts
    end

    def provisioning_status(member)
      current_email = normalize_email(member.email)
      current = member.provisioning_email.to_s == current_email
      local_slack_user = matching_slack_user(member)

      {
        activation_eligible: member.provisioning_eligible?,
        email: current_email,
        slack: {
          status: slack_status(member, current: current, matching_slack_user: local_slack_user),
          invite_confirmed_at: iso8601(member.slack_invite_confirmed_at),
          invite_source: member.slack_invite_source,
          invite_mode: member.slack_invite_mode,
          joined_at: iso8601(member.slack_joined_at),
          full_member_at: iso8601(member.slack_full_member_at),
          manual_action_required: member.slack_manual_action_required
        },
        google_drive: {
          status: google_status(member, current: current),
          resources_access_confirmed_at: iso8601(member.google_resources_access_confirmed_at),
          transfer_access_confirmed_at: iso8601(member.google_transfer_access_confirmed_at)
        }
      }
    end

    private

    def ensure_slack_invite_allowed!(member)
      if blocked_status?(member)
        raise Error::NotAllowed.new('Slack invites are not allowed for revoked or inactive members')
      end
    end

    def ensure_google_provisioning_allowed!(member)
      unless member.provisioning_eligible?
        raise Error::NotAllowed.new(
          'Google Drive access requires a future expiration, a usable fob, and a non-revoked, non-inactive status'
        )
      end
      unless ENV['GDRIVE_INVITES_ENABLED'] == 'true'
        raise Error::NotAllowed.new('Google Drive invites are not enabled in this environment')
      end
    end

    def blocked_status?(member)
      %w[revoked inactive].include?(member.status)
    end

    def matching_slack_user(member)
      email = normalize_email(member.email)
      return nil if email.blank?

      associated = member.slack_user
      return associated if normalize_email(associated&.slack_email) == email

      SlackUser.where(slack_email: /\A#{Regexp.escape(email)}\z/i).first
    end

    def confirm_slack_invite(member, source:, mode: nil)
      attrs = {
        slack_invite_confirmed_at: member.slack_invite_confirmed_at || Time.current,
        slack_invite_source: member.slack_invite_source.presence || source,
        slack_manual_action_required: nil,
        slack_last_error: nil
      }
      attrs[:slack_invite_mode] = mode if mode.present?
      attrs[:slack_acceptance_pending] = true if source == 'api'
      member.set(attrs)
    end

    def mark_manual_action(member, action, error)
      raise ArgumentError, "Unknown Slack manual action #{action}" unless SLACK_MANUAL_ACTIONS.include?(action)

      changed = member.slack_manual_action_required != action
      member.set(
        slack_manual_action_required: action,
        slack_last_error: error_message(error)
      )
      return unless changed

      audit(
        member,
        "slack_manual_#{action}_required",
        "Manual Slack #{action} required for #{member.email}: #{error_message(error)}",
        slack_channel: ::Service::SlackConnector.admin_channel
      )
      Honeybadger.notify(
        error,
        context: { member_id: member.id.to_s, member_email: member.email, manual_action: action }
      ) if defined?(Honeybadger)
    rescue => notification_error
      Rails.logger.error(
        "[MemberProvisioning] could not record manual Slack action: #{error_message(notification_error)}"
      )
    end

    def ensure_google_permission(member, field:, folder_id:, role:, adequate_roles:, label:)
      raise Error::NotAllowed.new("#{label} folder is not configured") if folder_id.blank?
      return { status: :confirmed } if member.public_send(field).present?

      drive = ::Service::GoogleDrive.load_gdrive
      permissions = drive.list_permissions(
        folder_id,
        fields: 'permissions(id,emailAddress,role)'
      )
      permission = Array(permissions.permissions).find do |candidate|
        normalize_email(candidate.email_address) == normalize_email(member.email)
      end

      if permission.nil?
        drive.create_permission(
          folder_id,
          Google::Apis::DriveV3::Permission.new(
            type: 'user',
            email_address: member.email,
            role: role
          )
        )
      elsif !adequate_roles.include?(permission.role.to_s)
        drive.update_permission(
          folder_id,
          permission.id,
          Google::Apis::DriveV3::Permission.new(role: role)
        )
      end

      member.set(field => Time.current)
      audit(member, 'google_drive_access_confirmed', "#{label} access confirmed as #{role}")
      { status: permission.nil? ? :created : :confirmed }
    end

    def lookup_slack_user(email)
      return nil unless ::Service::SlackConnector.api_token_present?

      response = ::Service::SlackConnector.client.users_lookupByEmail(email: email)
      response.respond_to?(:user) ? response.user : response['user']
    rescue Slack::Web::Api::Errors::UsersNotFound
      nil
    rescue => error
      Rails.logger.warn("[MemberProvisioning] Slack lookup failed for #{email}: #{error_message(error)}")
      nil
    end

    def slack_users_by_email
      return {} unless ::Service::SlackConnector.api_token_present?

      users = {}
      cursor = nil
      loop do
        response = ::Service::SlackConnector.client.users_list(
          limit: 200,
          cursor: cursor
        )
        Array(response.respond_to?(:members) ? response.members : response['members']).each do |user|
          email = live_user_email(user)
          users[email] = user if email.present?
        end
        cursor = if response.respond_to?(:response_metadata)
          response.response_metadata&.next_cursor.to_s
        else
          response.dig('response_metadata', 'next_cursor').to_s
        end
        break if cursor.blank?
      end
      users
    rescue => error
      Rails.logger.error("[MemberProvisioning] Slack user reconciliation unavailable: #{error_message(error)}")
      Honeybadger.notify(error) if defined?(Honeybadger)
      {}
    end

    def ensure_slack_user_record(member, live_user)
      slack_id = slack_value(live_user, 'id').to_s
      return if slack_id.blank?

      attributes = {
        slack_email: normalize_email(member.email),
        name: slack_value(live_user, 'name').to_s,
        real_name: slack_profile_value(live_user, 'real_name').to_s,
        member_id: member.id
      }
      record = SlackUser.find_by(slack_id: slack_id)
      record ? record.set(attributes) : SlackUser.create!(attributes.merge(slack_id: slack_id))
    end

    def google_permission_emails(folder_id, adequate_roles)
      return Set.new if folder_id.blank?

      permissions = ::Service::GoogleDrive.load_gdrive.list_permissions(
        folder_id,
        fields: 'permissions(emailAddress,role)'
      )
      Array(permissions.permissions).each_with_object(Set.new) do |permission, emails|
        next unless adequate_roles.include?(permission.role.to_s)

        email = normalize_email(permission.email_address)
        emails << email if email.present?
      end
    rescue => error
      Rails.logger.error("[MemberProvisioning] Google permission backfill unavailable: #{error_message(error)}")
      Honeybadger.notify(error) if defined?(Honeybadger)
      Set.new
    end

    def google_complete?(member)
      member.google_resources_access_confirmed_at.present? &&
        member.google_transfer_access_confirmed_at.present?
    end

    def slack_status(member, current:, matching_slack_user:)
      return 'blocked' if blocked_status?(member)
      return 'unknown' unless current
      return "manual_#{member.slack_manual_action_required}_required" if member.slack_manual_action_required.present?
      return 'full_member' if member.slack_full_member_at.present?
      if member.slack_joined_at.present?
        return member.slack_invite_mode == 'single_channel_guest' ? 'guest' : 'invite_confirmed'
      end
      return 'invite_pending' if member.slack_acceptance_pending == true
      return 'invite_confirmed' if member.slack_invite_confirmed_at.present? || matching_slack_user
      return 'not_invited' if member.provisioning_initialized_at.present?

      'unknown'
    end

    def google_status(member, current:)
      return 'blocked' if blocked_status?(member)
      return 'unknown' unless current
      resources = member.google_resources_access_confirmed_at.present?
      transfer = member.google_transfer_access_confirmed_at.present?
      return 'complete' if resources && transfer
      return 'partial' if resources || transfer
      return 'pending_activation' unless member.provisioning_eligible?
      return 'failed' if member.google_last_error.present?

      'not_provisioned'
    end

    def live_user_email(user)
      normalize_email(slack_profile_value(user, 'email'))
    end

    def slack_profile_value(user, key)
      profile = slack_value(user, 'profile')
      return profile.public_send(key) if profile.respond_to?(key)
      return profile[key] if profile.respond_to?(:[])

      nil
    end

    def slack_value(user, key)
      return user.public_send(key) if user.respond_to?(key)
      return user[key] if user.respond_to?(:[])

      nil
    end

    def normalize_email(email)
      email.to_s.strip.downcase
    end

    def iso8601(value)
      value&.utc&.iso8601
    end

    def error_message(error)
      "#{error.class}: #{error.message.to_s.gsub(/\s+/, ' ').strip}".first(2_000)
    end

    def audit(member, event_type, details, slack_channel: nil)
      ::Service::AuditLogger.log(
        log_type: 'member',
        event_type: event_type,
        resource_type: 'Member',
        resource_id: member.id,
        subject: member,
        message_details: details,
        slack_channel: slack_channel
      )
    rescue => error
      Rails.logger.error("[MemberProvisioning] audit failed: #{error_message(error)}")
    end

    def audit_failure(member, event_type, error)
      Rails.logger.error(
        "[MemberProvisioning] #{event_type} member_id=#{member.id}: #{error_message(error)}"
      )
      audit(member, event_type, error_message(error))
      Honeybadger.notify(error, context: { member_id: member.id.to_s }) if defined?(Honeybadger)
    end
  end
end
