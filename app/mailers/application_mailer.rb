class ApplicationMailer < ActionMailer::Base
  default from: ENV.fetch('SMTP_FROM', 'contact@manchestermakerspace.org')
  layout 'mailer'

  after_action :suppress_member_delivery

  private

  def suppress_member_delivery
    member = delivery_recipient_member
    unless member
      # The scoped lookup above does not see soft-deleted members, so a recipient with no live member is
      # checked against the deleted ones. If a live member now holds the address (a soft delete frees it
      # for reuse), that member was found above and the mail goes out normally.
      mail.perform_deliveries = false if soft_deleted_recipient?
      return
    end

    if member.direct_notifications_suppressed?
      mail.perform_deliveries = false
      return
    end

    return unless mailer_name == "member_mailer"
    return if household_secondary_exempt_member_mailer_action?

    mail.perform_deliveries = false if member.household_role == :secondary
  end

  def household_secondary_exempt_member_mailer_action?
    # Secondaries are bound by the same contract as everyone else and need a signed Member
    # Contract before they can request any checkout, so the contract mail must reach them.
    %w[
      household_disbanded password_changed admin_password_reset
      send_document contract_updated request_document
    ].include?(action_name)
  end

  def delivery_recipient_member
    recipient_email = Array(mail.to).first.to_s.downcase
    return if recipient_email.blank?

    Member.find_by(email: recipient_email)
  end

  def soft_deleted_recipient?
    recipient_email = Array(mail.to).first.to_s.downcase
    return false if recipient_email.blank?

    Member.unscoped.where(email: recipient_email, :merged_at.ne => nil).exists?
  end
end
