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
    @member.update!(get_camel_case_params(update_member_params()))
    notify_renewal(date)
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
