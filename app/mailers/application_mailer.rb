class ApplicationMailer < ActionMailer::Base
  default from: ENV.fetch('SMTP_FROM', 'contact@manchestermakerspace.org')
  layout 'mailer'

  # Record email metadata immediately after each mail() call so we have the
  # subject available when Mailtrap fires a webhook later.
  # Runs after every action in every mailer that inherits ApplicationMailer.
  after_action :record_mailtrap_message

  private

  def record_mailtrap_message
    return unless message.present?

    # ActionMailer sets Message-ID automatically. Strip angle brackets for clean storage.
    msg_id = message.message_id.to_s.gsub(/\A<|>\z/, '')
    return if msg_id.blank?

    # Recipient — take first To: address
    recipient = Array(message.to).first
    return if recipient.blank?

    # Attempt to find the member by email — nil is acceptable, don't block delivery
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
    # Never let message recording break email delivery
    Rails.logger.error("[ApplicationMailer] record_mailtrap_message failed: #{e.message}")
    Honeybadger.notify(e) if defined?(Honeybadger)
  end
end
