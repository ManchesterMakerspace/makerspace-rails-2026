class ApplicationMailer < ActionMailer::Base
  default from: ENV.fetch('SMTP_FROM', 'contact@manchestermakerspace.org')
  layout 'mailer'

  after_action :suppress_secondary_household_member_delivery

  private

  def suppress_secondary_household_member_delivery
    return if mailer_name == "marketing_mailer"
    return if mailer_name == "member_mailer" && action_name == "household_disbanded"

    member = delivery_recipient_member
    mail.perform_deliveries = false if member&.household_role == :secondary
  end

  def delivery_recipient_member
    recipient_email = Array(mail.to).first.to_s.downcase
    return if recipient_email.blank?

    Member.find_by(email: recipient_email)
  end
end
