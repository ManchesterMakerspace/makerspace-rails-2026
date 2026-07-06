class ApplicationMailer < ActionMailer::Base
  default from: ENV.fetch('SMTP_FROM', 'contact@manchestermakerspace.org')
  layout 'mailer'

  after_action :suppress_member_delivery

  private

  def suppress_member_delivery
    member = delivery_recipient_member
    return unless member

    if member.direct_notifications_suppressed?
      mail.perform_deliveries = false
      return
    end

    return unless mailer_name == "member_mailer"
    return if action_name == "household_disbanded"

    mail.perform_deliveries = false if member.household_role == :secondary
  end

  def delivery_recipient_member
    recipient_email = Array(mail.to).first.to_s.downcase
    return if recipient_email.blank?

    Member.find_by(email: recipient_email)
  end
end
