class RegistrationsController < ApplicationController
  include BraintreeGateway
  include ApplicationHelper
  respond_to :json

  before_action :authenticate_registration_email_token, only: [:new]

  def new
    email = new_member_params[:email].to_s.strip.downcase
    member = Member.find_by(email: email)
    if member
      error = "Cannot send registration to #{email}. Account already exists"
      enque_message(error)
      raise ::Error::AccountExists
    end
    MemberMailer.welcome_email(email).deliver_later
    render json: {}, status: 204 and return
  end

  def create
    @member = Member.new(member_params)
    @member.save!
    @member.reload
    sign_in(@member)
    MemberMailer.member_registered(@member.id.to_s).deliver_later

    ::Service::AuditLogger.log(
      log_type:       'member',
      event_type:     'member_registered',
      resource_type:  'Member',
      resource_id:    @member.id,
      actor:          @member,
      subject:        @member,
      after_snapshot: { email: @member.email, firstname: @member.firstname,
                        lastname: @member.lastname }
    )

    render json: @member, adapter: :attributes and return
  end

  private
  def authenticate_registration_email_token
    registration_email_token = ENV["REGISTRATION_EMAIL_TOKEN"].to_s
    return if registration_email_token.blank?

    email = params[:email].to_s.strip.downcase
    return if email.blank?

    expected_token = OpenSSL::HMAC.hexdigest("SHA256", registration_email_token, email).first(16)
    provided_token = params[:token].to_s

    unless provided_token.bytesize == expected_token.bytesize &&
        ActiveSupport::SecurityUtils.secure_compare(provided_token, expected_token)
      raise ::Error::Unauthorized.new
    end
  end

  def new_member_params
    params.require(:email)
    params.permit(:email)
  end 

  def member_params
    params.require([:firstname, :lastname, :email, :password])
    params.permit(:firstname, :lastname, :email, :password,
      :phone, address: [:street, :unit, :city, :state, :postal_code])
  end
end
