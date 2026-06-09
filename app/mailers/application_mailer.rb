class ApplicationMailer < ActionMailer::Base
  default from: ENV.fetch('SMTP_FROM', 'contact@manchestermakerspace.org')
  layout 'mailer'

  after_action :record_mailtrap_message

  private

  def record_mailtrap_message
    return unless message.present?

    msg_id = message.message_id.to_s.gsub(/\A<|>\z/, '')
    return if msg_id.blank?

    recipient = Array(message.to).first
    return if recipient.blank?

    member = Member.where(email: recipient).first

    MailtrapMessage.create(
      message_id:   msg_id,
      subject:      message.subject.to_s,
      email:        recipient,
      mailer_class: self.class.name,
      action:       action_name,
      member_id:    member&.id
    )
  rescue => e
    Rails.logger.error("[ApplicationMailer] record_mailtrap_message failed: #{e.message}")
    Honeybadger.notify(e) if defined?(Honeybadger)
  end
end
