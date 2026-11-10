# Why a Braintree charge failed, kept on the invoice so the portal, the email and the Slack messages can all say so, and so
# "Pay now" knows whether trying again is worth it.
#
# Braintree marks every declined charge with a processor_response_type: "soft_declined" (a temporary problem such as
# insufficient funds, worth trying again) or "hard_declined" (the card itself is the problem: expired, closed, reported
# lost, ... and retrying it will not help or can annoy the issuer). A gateway rejection (for example a security code or
# address check) has no such type, so its status is stored instead.
#
# Invoice fields written here:
#   last_failure_type    "soft_declined", "hard_declined", the transaction status for other failures, "unknown" when a
#                        look-up found nothing useful, or "cleared" once the member changed the payment method
#   last_failure_message plain wording safe to show the member ("insufficient funds"); nil when we cannot say why.
#                        It never holds a raw bank response; board members get that from the transaction in the Slack note.
module PaymentFailure
  SOFT = ::Braintree::ProcessorResponseTypes::SoftDeclined
  HARD = ::Braintree::ProcessorResponseTypes::HardDeclined
  UNKNOWN = 'unknown'.freeze
  CLEARED = 'cleared'.freeze

  GENERIC_BANK_DECLINE = "your bank declined it, please contact your bank".freeze

  # Braintree processor response codes with a wording more useful than the generic one. Anything else from the processor
  # gets GENERIC_BANK_DECLINE: that is what we know, rather than a guess.
  MESSAGES_BY_CODE = {
    '2001' => 'insufficient funds',
    '2002' => "the card's limit was reached",
    '2003' => "the card's limit was reached",
    '2004' => 'the card has expired',
    '2006' => "the card's expiration date was not accepted",
    '2005' => 'the card number was not accepted',
    '2007' => 'the card number was not accepted',
    '2008' => 'the card number was not accepted',
    '2009' => 'the card number was not accepted',
    '2010' => "the card's security code was not accepted"
  }.freeze

  MESSAGES_BY_GATEWAY_REJECTION = {
    'cvv' => "the card's security code was not accepted",
    'avs' => "the billing address or postal code did not match the card",
    'avs_and_cvv' => "the billing address and security code did not match the card"
  }.freeze

  class << self
    # What can be said about a failed transaction: { type:, message:, code:, text: }. +message+ is for the member;
    # +code+ and +text+ are the processor's own response, for board members only.
    def describe(transaction)
      return { type: nil, message: nil, code: nil, text: nil } if transaction.nil?

      code = transaction.try(:processor_response_code).to_s.presence
      text = transaction.try(:processor_response_text).to_s.presence
      rejection = transaction.try(:gateway_rejection_reason).to_s.presence
      status = transaction.try(:status).to_s.presence
      type = transaction.try(:processor_response_type).to_s.presence || status

      message =
        if code
          MESSAGES_BY_CODE.fetch(code, GENERIC_BANK_DECLINE)
        elsif rejection
          MESSAGES_BY_GATEWAY_REJECTION[rejection]
        elsif status == ::Braintree::Transaction::Status::ProcessorDeclined
          GENERIC_BANK_DECLINE
        end

      { type: type, message: message, code: code, text: text }
    end

    # Stores which transaction failed and why, ahead of any message being sent about it.
    def record!(invoice, transaction)
      details = describe(transaction)
      invoice.update!(
        last_failed_transaction_id: transaction.id,
        last_failure_type: details[:type] || UNKNOWN,
        last_failure_message: details[:message]
      )
      details
    end

    # The member changed the payment method, so a hard decline of the old one no longer applies. The failed
    # transaction id stays: it marks that this invoice's subscription had a failed charge.
    def clear!(invoice)
      return if invoice.nil?

      invoice.update!(last_failure_type: CLEARED, last_failure_message: nil)
    end

    def hard_decline?(invoice)
      invoice.present? && invoice.last_failure_type == HARD
    end

    # Invoices whose charge failed before the reason was stored have a failed transaction id but no reason. Read that
    # transaction from Braintree once and save what it says, so the portal can show it. A look-up that fails is not
    # saved, so it is tried again next time; one that finds nothing useful is saved as "unknown".
    def ensure_recorded(gateway, invoice)
      return invoice if invoice.nil? || invoice.last_failed_transaction_id.blank? || invoice.last_failure_type.present?

      transaction = gateway.transaction.find(invoice.last_failed_transaction_id)
      record!(invoice, transaction)
      invoice
    rescue ::Braintree::NotFoundError
      invoice.update!(last_failure_type: UNKNOWN)
      invoice
    rescue StandardError => error
      Rails.logger.warn("[PaymentFailure] could not read failed transaction #{invoice.last_failed_transaction_id}: #{error.class}")
      invoice
    end

    # How board members are told about a failure: "soft declined, response 2001 (Insufficient Funds)".
    def board_summary(details)
      parts = []
      parts << details[:type].to_s.tr('_', ' ') if details[:type].present?
      response = [details[:code], details[:text] && "(#{details[:text]})"].compact.join(' ')
      parts << "response #{response}" if response.present?
      parts.join(', ')
    end
  end
end
