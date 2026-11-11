# "Pay now": a member charging the past-due balance of their own Braintree subscription right away instead of waiting for
# Braintree's retry schedule (a failed charge does not extend the membership, so access can lapse during the wait).
#
# Braintree's retry-charge call only applies to a subscription whose status is Past Due, and charges the balance owed (no
# amount is passed: on success Braintree zeroes the balance whatever amount a retry names). A hard decline disables the
# button until the member changes the payment method, and PayNowLimit keeps the attempts few. Nothing here sends mail or a
# direct message to the member: they see the answer on the screen.
module PayNow
  # A request that is turned down before it reaches Braintree. +status+ is the HTTP status, +reason+ a short code the screen
  # can act on ("hard_decline", "cooldown", "daily_cap"), +retry_at+ when they can try again (or nil).
  class Refused < StandardError
    attr_reader :status, :reason, :retry_at

    def initialize(status, reason, message, retry_at = nil)
      super(message)
      @status = status
      @reason = reason
      @retry_at = retry_at
    end
  end

  # The answer to an attempt that reached Braintree. +paid+ is true when the charge went through.
  Outcome = Struct.new(:paid, :transaction, :invoice, :failure, keyword_init: true) do
    def paid?
      paid
    end
  end

  HANDLED_TTL_SECONDS = 24 * 60 * 60

  class << self
    # Whether the member could press the button now, and if not, why: { can_pay_now:, blocked_reason:, next_at:,
    # failure_message: }. Reads only, so it is safe for lists; only a past-due subscription looks anything up.
    def info_for(subscription)
      none = { can_pay_now: false, blocked_reason: nil, next_at: nil, failure_message: nil }
      return none unless past_due?(subscription)

      invoice = invoice_for(subscription.id)
      return none.merge(blocked_reason: 'unavailable') if invoice.nil?

      message = invoice.last_failure_message
      if PaymentFailure.hard_decline?(invoice)
        return none.merge(blocked_reason: 'hard_decline', failure_message: message)
      end

      limit = PayNowLimit.status(subscription.id)
      if limit[:state] == :available
        none.merge(can_pay_now: true, failure_message: message)
      else
        none.merge(blocked_reason: limit[:state].to_s, next_at: limit[:retry_at], failure_message: message)
      end
    end

    # Fills in the reason for a failure that happened before reasons were stored, so the screen can show it.
    def ensure_failure_reason(gateway, subscription)
      return unless past_due?(subscription)

      PaymentFailure.ensure_recorded(gateway, invoice_for(subscription.id))
    end

    # Runs one attempt for +member+'s own subscription +subscription_id+ (the controller has already checked it is theirs).
    # Raises PayNow::Refused or an Error::* when it cannot go ahead; otherwise returns an Outcome.
    def attempt!(gateway, member, subscription_id)
      subscription = ::BraintreeService::Subscription.get_subscription(gateway, subscription_id)
      unless past_due?(subscription)
        raise ::Error::UnprocessableEntity.new("This payment is not past due, so there is nothing to pay now.")
      end

      invoice = invoice_for(subscription_id)
      if invoice.nil?
        raise ::Error::UnprocessableEntity.new("We could not find the unpaid invoice for this payment. Please contact support.")
      end

      PaymentFailure.ensure_recorded(gateway, invoice)
      invoice.reload
      if PaymentFailure.hard_decline?(invoice)
        raise Refused.new(422, 'hard_decline', "Your card was declined and cannot be tried again. Update your payment method first.")
      end

      PayNowLimit.claim!(subscription_id)
      result = begin
        ::BraintreeService::Subscription.retry_charge(gateway, subscription_id)
      rescue StandardError
        PayNowLimit.release(subscription_id)
        raise
      end

      transaction = result.transaction
      if result.success?
        settle(invoice, transaction, member)
      else
        decline(invoice, transaction, member)
      end
    end

    # True when this transaction was already settled by Pay now, so Braintree's own "charged successfully" notification for
    # the same charge has nothing left to do (and need not post a duplicate note).
    def handled?(transaction_id)
      transaction_id.present? && REDIS.exists?("pay_now_handled/#{transaction_id}")
    end

    def invoice_for(subscription_id)
      Invoice.where(subscription_id: subscription_id, settled_at: nil, transaction_id: nil).asc(:created_at).first
    end

    private

    def past_due?(subscription)
      subscription.status == ::Braintree::Subscription::Status::PastDue
    end

    def settle(invoice, transaction, member)
      matching = BraintreeService::Notification.find_invoice_matching_transaction_amount(transaction) do |amount|
        Invoice.oldest_active_subscription_invoice_matching_amount(
          subscription_id: invoice.subscription_id,
          plan_id: invoice.plan_id,
          resource_id: invoice.resource_id,
          member_id: invoice.member_id,
          resource_class: invoice.resource_class,
          amount: amount
        )
      end
      target = matching || invoice
      ::BraintreeService::Notification.process_subscription_charge_success(target, transaction)
      REDIS.set("pay_now_handled/#{transaction.id}", '1', ex: HANDLED_TTL_SECONDS) if target.reload.settled

      audit(member, target, 'paid', transaction, "Paid the past-due #{target.name} payment of $#{format('%.2f', transaction.amount.to_d)} with Pay now.")
      note_board(member, target, "paid their past-due #{target.name} payment of $#{format('%.2f', transaction.amount.to_d)} with Pay now.")
      Outcome.new(paid: true, transaction: transaction, invoice: target)
    end

    def decline(invoice, transaction, member)
      details = PaymentFailure.record!(invoice, transaction)
      reason = details[:message] ? " (#{details[:message]})" : ''
      summary = PaymentFailure.board_summary(details)

      audit(member, invoice, 'declined', transaction, "Pay now was declined for #{invoice.name}#{summary.present? ? ": #{summary}" : ''}.")
      note_board(member, invoice, "tried to pay their past-due #{invoice.name} payment with Pay now and it was declined#{reason}#{summary.present? ? " [#{summary}]" : ''}.#{details[:type] == PaymentFailure::HARD ? ' It will not retry until the member changes their payment method.' : ''}")
      Outcome.new(paid: false, transaction: transaction, invoice: invoice, failure: details)
    end

    def audit(member, invoice, outcome, transaction, message)
      ::Service::AuditLogger.log(
        log_type: 'member',
        event_type: 'subscription_pay_now',
        resource_type: 'Invoice',
        resource_id: invoice.id,
        actor: member,
        subject: member,
        after_snapshot: {
          subscription_id: invoice.subscription_id,
          outcome: outcome,
          transaction_id: transaction.id,
          failure_type: invoice.reload.last_failure_type
        },
        message_details: message
      )
    end

    def note_board(member, invoice, text)
      ::Service::SlackConnector.enque_message(
        "#{BraintreeService::Notification.get_member_profile(member)} #{text}",
        ::Service::SlackConnector.members_relations_channel,
        ::Service::SlackConnector.request_caller_id("pay_now.#{invoice.id}")
      )
    end
  end
end
