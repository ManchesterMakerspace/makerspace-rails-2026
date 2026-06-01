class Admin::MembersController < AdminController
  include Service::GoogleDrive
  before_action :set_member, only: [:update, :update_password, :send_password_reset, :invite_google_drive, :invite_slack]

  def create
    @member = Member.new(get_camel_case_params(create_member_params()))
    @member.save!
    @member.reload
    send_welcome_email
    render json: @member, adapter: :attributes and return
  end

  def update
    date = @member.expirationTime
    becoming_revoked = params[:status] == 'revoked' && @member.status != 'revoked'
    incoming_params = get_camel_case_params(update_member_params())
    slack_user = SlackUser.find_by(member_id: @member.id)
    previous_firstname = @member.firstname
    previous_lastname = @member.lastname
    previous_status = @member.status
    previous_expiration_time = @member.expirationTime

    @member.update!(incoming_params)

    if becoming_revoked
      handle_revocation
    end

    notify_renewal(date)
    update_slack_profile(slack_user, previous_firstname, previous_lastname, previous_status, previous_expiration_time)
    update_slack_user_groups(slack_user, previous_status)
    @member.reload
    render json: @member, adapter: :attributes and return
  end

  # POST /api/admin/members/:id/update_password
  # Admin directly sets a new password for any member, then emails a notification.
  def update_password
    password = password_params[:password]
    raise ::Error::UnprocessableEntity.new("Password cannot be blank") if password.blank?
    raise ::Error::UnprocessableEntity.new("Password is too short (minimum 8 characters)") if password.length < 8

    @member.password = password
    @member.save!
    MemberMailer.password_changed(@member.id.to_s).deliver_later
    render json: {}, status: 204 and return
  end

  # POST /api/admin/members/:id/send_password_reset
  # Admin triggers a Devise reset-link email (member sets their own password via link).
  def send_password_reset
    send_set_password_email
    render json: {}, status: 204 and return
  end

  # POST /api/admin/members/:id/invite_google_drive
  # Re-sends a Google Drive folder invite to the member.
  def invite_google_drive
    invite_gdrive(@member.email)
    render json: {}, status: 204 and return
  rescue Error::NotAllowed => e
    render json: { message: e.message }, status: :unprocessable_entity and return
  rescue => e
    Honeybadger.notify(e) if defined?(Honeybadger)
    render json: { message: e.message }, status: :unprocessable_entity and return
  end

  # POST /api/admin/members/:id/invite_slack
  # Re-sends a Slack workspace invite to the member's email.
  # Safe to call even if the member is already in the workspace — Slack
  # will return an error which is surfaced to the admin.
  def invite_slack
    ::Service::SlackConnector.invite_to_slack(@member.email, @member.lastname, @member.firstname)
    render json: {}, status: 204 and return
  rescue Error::NotAllowed => e
    render json: { message: e.message }, status: :unprocessable_entity and return
  rescue => e
    Honeybadger.notify(e) if defined?(Honeybadger)
    render json: { message: e.message }, status: :unprocessable_entity and return
  end

  private

  # Cancel subscription, revoke Drive/Slack access, and invalidate all sessions
  # when a member's status is set to revoked.
  def handle_revocation
    # Cancel Braintree subscription if present
    if @member.subscription_id
      begin
        ::BraintreeService::Subscription.cancel(connect_gateway, @member.subscription_id)
      rescue => e
        ::Service::SlackConnector.send_slack_message(
          "⚠️ Error cancelling subscription for revoked member #{@member.fullname}: #{e.message}",
          ::Service::SlackConnector.logs_channel
        )
      end
    end

    # Revoke Google Drive and Slack access
    begin
      Service::MemberAccess.revoke(@member)
    rescue => e
      ::Service::SlackConnector.send_slack_message(
        "⚠️ Error revoking Drive/Slack access for #{@member.fullname}: #{e.message}",
        ::Service::SlackConnector.logs_channel
      )
    end

    # Silence all email/slack notifications to the member
    @member.update_attribute(:silence_emails, true)

    # Rotate session token to invalidate any active portal sessions
    @member.update_attribute(:session_token, SecureRandom.hex)
  end

  def create_member_params
    params.require([:firstname, :lastname, :email])
    params.permit(:firstname, :lastname, :role, :email, :status,
      :silence_emails, :member_contract_on_file, :phone, :notes, address: [:street, :city, :state, :postal_code])
  end

  def update_member_params
    # Email intentionally excluded — changing email requires its own validation flow
    # and including it triggers Mongoid uniqueness re-validation on unchanged values
    params.permit(:firstname, :lastname, :role, :status, :expiration_time, :renew, :member_contract_on_file, :notes,
      :silence_emails, :phone, :subscription, address: [:street, :unit, :city, :state, :postal_code])
  end

  def password_params
    params.require(:password)
    params.permit(:password)
  end

  def get_camel_case_params(member_params)
    camel_case_props = {
      expiration_time: :expirationTime,
      member_contract_on_file: :memberContractOnFile,
    }
    params = member_params
    camel_case_props.each do | key, value|
      params[value] = params.delete(key) unless params[key].nil?
    end
    params
  end

  def set_member
    @member = Member.find(params[:id])
    raise ::Mongoid::Errors::DocumentNotFound.new(Member, { id: params[:id] }) if @member.nil?
  end

  def notify_renewal(init)
    final = @member.expirationTime
    # Check if adding expiration too
    if final &&
        (init.nil? ||
        (Time.at(final / 1000) - Time.at((init || 0) / 1000) > 1.day))
      @member.send_renewal_slack_message(current_member)
    end
  end

  def update_slack_profile(slack_user, previous_firstname, previous_lastname, previous_status, previous_expiration_time)
    if slack_user.nil? || slack_user.slack_id.blank?
      Rails.logger.warn("Member #{previous_firstname} #{previous_lastname} has no slack account, no update possible.")
    end
    unless ENV['SLACK_ADMIN_TOKEN'].present?
      Rails.logger.info("Cannot update slack profile without a SLACK_ADMIN_TOKEN")
      return
    end

    status_changed = previous_status != @member.status || previous_expiration_time != @member.expirationTime
    name_changed = previous_firstname != @member.firstname || previous_lastname != @member.lastname
    return unless status_changed || name_changed

    client = Slack::Web::Client.new(token: ENV['SLACK_ADMIN_TOKEN'])

    profile = {}

    if status_changed
      status_field = ENV['SLACK_PROFILE_STATUS'].presence || 'Xf084350PJ8K'
      status_value = @member.expirationTime.present? && Time.at(@member.expirationTime / 1000) < Time.current ? 'Expired' : @member.status
      profile[status_field] = { value: status_value }
      Rails.logger.info("Updating #{@member.firstname} #{@member.lastname} profile status from #{previous_status} to #{status_value}.")
    end

    if name_changed
      fullname_field = ENV['SLACK_PROFILE_FULLNAME'].presence || 'Xf084350PJ8K'
      profile[fullname_field] = { value: "#{@member.firstname} #{@member.lastname} (#{slack_user.name})" }
      Rails.logger.info("Updating profile name fom #{previous_firstname} #{previous_lastname} to #{@member.firstname} #{@member.lastname}.")
    end

    client.users_profile_set(user: slack_user.slack_id, profile: profile) if profile.any?
  rescue Slack::Web::Api::Errors::SlackError => e
    ::Service::SlackConnector.send_slack_message(
      "⚠️ Error updating Slack profile for #{@member.fullname}: #{e.message}",
      ::Service::SlackConnector.logs_channel
    )
  end

  def update_slack_user_groups(slack_user, previous_status)
    return if slack_user.nil? || slack_user.slack_id.blank?
    return unless previous_status != @member.status
    return unless ENV['SLACK_ADMIN_TOKEN'].present?

    target_group, source_group =
      if %w[inactive suspended revoked].include?(@member.status.to_s)
        ['inactivemembers', 'activemembers']
      elsif @member.expirationTime.present? && Time.at(@member.expirationTime / 1000) > Time.current
        ['activemembers', 'inactivemembers']
      end

    return if target_group.nil? || source_group.nil?

    client = Slack::Web::Client.new(token: ENV['SLACK_ADMIN_TOKEN'])
    target_group_id = slack_user_group_id(client, target_group)
    source_group_id = slack_user_group_id(client, source_group)
    return if target_group_id.nil? || source_group_id.nil?

    add_user_to_slack_group(client, target_group_id, slack_user.slack_id)
    remove_user_from_slack_group(client, source_group_id, slack_user.slack_id)
  rescue Slack::Web::Api::Errors::SlackError => e
    ::Service::SlackConnector.send_slack_message(
      "⚠️ Error updating Slack groups for #{@member.fullname}: #{e.message}",
      ::Service::SlackConnector.logs_channel
    )
  end

  def slack_user_group_id(client, group_name)
    response = client.usergroups_list
    groups = response['usergroups'] || response[:usergroups] || []
    group = groups.find do |entry|
      entry_name = entry['name'] || entry[:name]
      entry_name.to_s == group_name
    end
    group && (group['id'] || group[:id])
  end

  def add_user_to_slack_group(client, group_id, slack_id)
    response = client.usergroups_users_list(usergroup: group_id)
    users = Array(response['users'] || response[:users]).map(&:to_s)
    return if users.include?(slack_id)
    Rails.logger.info("Adding #{@member.firstname} #{@member.lastname} to group #{group_id}.")
    client.usergroups_users_update(usergroup: group_id, users: (users + [slack_id]).join(','))
  end

  def remove_user_from_slack_group(client, group_id, slack_id)
    response = client.usergroups_users_list(usergroup: group_id)
    users = Array(response['users'] || response[:users]).map(&:to_s)
    return unless users.include?(slack_id)

    client.usergroups_users_update(usergroup: group_id, users: (users - [slack_id]).join(','))
  end

  def send_welcome_email
    raw_token, hashed_token = ::Devise.token_generator.generate(Member, :reset_password_token)
    @member.reset_password_token = hashed_token
    @member.reset_password_sent_at = Time.now.utc
    @member.save!
    MemberMailer.welcome_email_manual_register(@member.email, raw_token).deliver_now
  end

  def send_set_password_email
    @member.send_reset_password_instructions
  end
end
