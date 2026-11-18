require 'bigdecimal'
require 'securerandom'

# The only writer of the paid balance. Processor requests and notifications run
# outside these retryable transactions. A standalone database is never a fallback.
class MembershipPaidCredit
  GRACE_SECONDS = 240 * 60 * 60
  MAX_ATTEMPTS = 5
  AuditSubject = Struct.new(:id, :fullname)
  BALANCE_FIELDS = %w[continuous_paid_membership_months continuous_paid_membership_balance
    continuous_paid_membership_streak_id continuous_paid_membership_revision
    continuous_paid_membership_reset_key].freeze

  class << self
    def active?
      Thread.current[:membership_paid_transaction].present?
    end

    def after_commit(&block)
      active? ? Thread.current[:membership_paid_transaction][:effects] << block : block.call
    end

    # Mongoid queries inherit its thread-local session. Raw driver collection
    # operations do not; passing it explicitly is essential for atomicity.
    def session_options
      session = active? ? Thread.current[:membership_paid_transaction][:session] : Mongoid::Threaded.get_session
      session ? { session: session } : {}
    end

    def track!(record)
      Thread.current[:membership_paid_transaction][:records][record.object_id] = record if active?
      record
    end

    # A retry must reconstruct documents inside the supplied block. Generic
    # Mongoid saves use one attempt because callbacks clear their dirty state.
    def transaction(attempts: MAX_ATTEMPTS)
      owns_context = false
      return yield if active?
      # A surrounding card/ticket operation owns its existing transaction. Join
      # its session for atomic member/ledger writes without nesting or changing
      # the caller's commit, retry or notification policy. Paid invoice release
      # runs after card assignment commits and owns its bounded transaction here.
      if (existing_session = Mongoid::Threaded.get_session)
        raise Error::Conflict.new('The current database session has no active transaction. Refresh and retry.') unless existing_session.in_transaction?
        return yield
      end
      owns_context = true
      attempt = 0
      begin
        attempt += 1
        effects = []
        result = Member.with_session do |session|
          raise Error::Conflict.new('Finish the current database operation before changing membership.') if session.in_transaction?
          records = {}
          Thread.current[:membership_paid_transaction] = { effects: effects, session: session, records: records }
          begin
            session.start_transaction
            value = yield
            commit_attempt = 0
            begin
              commit_attempt += 1
              session.commit_transaction
            rescue Mongo::Error => error
              retry if error.label?('UnknownTransactionCommitResult') && commit_attempt < MAX_ATTEMPTS
              raise
            end
            value
          rescue Exception
            session.abort_transaction if session.in_transaction?
            raise
          ensure
            # Association criteria created inside a session retain that session.
            # Clear those cached relations before ending it, preserving saved
            # attributes and previous_changes needed by existing audit callers.
            records.each_value(&:reload_relations)
            Thread.current[:membership_paid_transaction] = nil
            session.end_session
          end
        end
      rescue Mongo::Error => error
        if error.label?('TransientTransactionError') && attempt < attempts
          sleep([0.1 * (2**(attempt - 1)), 0.8].min)
          retry
        end
        Rails.logger.error("[MembershipPaidCredit] transaction_failed type=#{error.class} code=#{error.respond_to?(:code) ? error.code : nil}")
        raise Error::Conflict.new('Membership changed concurrently. Refresh and retry.') if error.label?('TransientTransactionError') || (error.respond_to?(:code) && error.code == 11000)
        raise Error::UnprocessableEntity.new('Membership changes require an available MongoDB replica set. Please retry.')
      end
      effects.each(&:call)
      result
    ensure
      Thread.current[:membership_paid_transaction] = nil if owns_context
    end

    def decimal(value)
      value.is_a?(BigDecimal) ? value : BigDecimal(value.to_s)
    end

    def balance(document)
      decimal(document['continuous_paid_membership_balance'] || '0')
    end

    def expired?(document, at: Time.current)
      expiry = document['expirationTime']
      expiry.present? && at.to_r * 1000 >= expiry.to_i + GRACE_SECONDS * 1000
    end

    def representation(document, at: Time.current)
      zero = document['status'] == 'revoked' || expired?(document, at: at)
      { continuousPaidMembershipMonths: zero ? 0 : [balance(document), 0].max.floor,
        revision: document['continuous_paid_membership_revision'].to_i,
        estimated: document['continuous_paid_membership_estimated'] != false }
    end

    def read(member_id)
      representation(document!(member_id))
    end

    def document!(member_id, include_deleted: false)
      if member_id.is_a?(String)
        raise Error::NotFound.new unless BSON::ObjectId.legal?(member_id)
        member_id = BSON::ObjectId.from_string(member_id)
      end
      selector = { _id: member_id }
      selector[:merged_at] = nil unless include_deleted
      Member.collection.find(selector, session_options).first || raise(Error::NotFound.new)
    end

    def source_key(invoice)
      invoice.transaction_id.present? ? "braintree:#{invoice.transaction_id}" : "invoice:#{invoice.id}"
    end

    def before_member_change!(member)
      track!(member)
      document = document!(member.id)
      if member.expirationTime_changed? && document['expirationTime'] != member.expirationTime_was
        raise Error::Conflict.new('Membership expiration changed. Refresh and retry.')
      end
      if member.status_changed? && document['status'] != member.status_was
        raise Error::Conflict.new('Membership status changed. Refresh and retry.')
      end
      document = reset_if_due!(document, revoked: member.status == 'revoked')
      document = write_balance!(document, balance(document))
      BALANCE_FIELDS.each { |field| member.write_attribute(field, document[field]) }
    end

    def change_expiration!(member_id, expiration)
      transaction do
        document = reset_if_due!(document!(member_id))
        write_balance!(document, balance(document), extra: { expirationTime: expiration })
      end
    end

    def reset_if_due!(document, at: Time.current, revoked: false)
      reason = if revoked || document['status'] == 'revoked'
        'revoked'
      elsif expired?(document, at: at)
        "expiration:#{document['expirationTime']}"
      end
      return document unless reason
      return document if document['continuous_paid_membership_reset_key'] == reason && balance(document).zero?
      old_streak = document['continuous_paid_membership_streak_id'] || "legacy:#{document['_id']}"
      entry!(document, source_key: "reset:#{old_streak}", action: 'reset', action_key: reason,
        streak_id: old_streak, months: -balance(document), balance_delta: -balance(document),
        occurred_at: at, details: { reason: reason })
      write_balance!(document, 0, streak: SecureRandom.uuid,
        extra: { continuous_paid_membership_reset_key: reason })
    end

    def sweep!(at: Time.current)
      selector = { merged_at: nil, continuous_paid_membership_balance: { '$gt' => BSON::Decimal128.new('0') },
        '$or' => [{ expirationTime: { '$lte' => (at.to_r * 1000).floor - GRACE_SECONDS * 1000 } }, { status: 'revoked' }] }
      count = 0
      Member.collection.find(selector).projection(_id: 1).each do |candidate|
        changed = transaction do
          current = document!(candidate['_id'])
          reset_if_due!(current, at: at)['continuous_paid_membership_revision'] != current['continuous_paid_membership_revision']
        end
        count += 1 if changed
      end
      Rails.logger.info("[MembershipPaidCredit] reset_count=#{count}")
      count
    end

    def apply_invoice!(invoice_id)
      transaction do
        invoice = Invoice.find(invoice_id)
        raise Error::NotFound.new unless invoice
        new_attempt = invoice.membership_paid_reversed_at.present? && invoice.transaction_id.present? &&
          invoice.transaction_id != invoice.last_failed_transaction_id
        if (invoice.membership_paid_applied_at && !new_attempt) || invoice.settled_at
          Rails.logger.info("[MembershipPaidCredit] duplicate_application invoice_id=#{invoice.id}")
          next false
        end
        next false if (invoice.refunded && !new_attempt) || (invoice.membership_paid_reversed_at && !new_attempt) ||
          (invoice.transaction_id.present? && invoice.last_failed_transaction_id == invoice.transaction_id)
        if new_attempt
          # The old attempt remains in the ledger. Its reversal already removed
          # its credit; the new charge receives a distinct source identity.
          invoice.update!(membership_paid_applied_at: nil, membership_paid_reversed_at: nil,
            membership_paid_recipient_ids: [], membership_paid_source_key: nil,
            membership_paid_refunds: [], refunded: false)
        end
        resource = invoice.resource
        raise Error::NotFound.new unless resource
        track!(resource)
        resource.reactivate_for_payment! if resource.is_a?(Member)
        next :held if resource.respond_to?(:delay_invoice_operation) && resource.delay_invoice_operation(invoice.operation)
        invoice.inc(membership_paid_operation_revision: 1)
        recipients = recipients_for(invoice, resource)
        before = recipients.to_h { |id| [id, document!(id)['expirationTime']] }
        raise Error::UnprocessableEntity.new('Unable to apply membership duration.') unless resource.execute_operation(invoice.operation, invoice)
        at = Time.current
        recipients.each do |id|
          document = reset_if_due!(document!(id))
          streak = document['continuous_paid_membership_streak_id'] || SecureRandom.uuid
          streak = "revoked:#{SecureRandom.uuid}" if document['status'] == 'revoked'
          refunded = invoice.membership_paid_refunds.sum { |r| decimal(r['amount']) }
          months = decimal(invoice.quantity)
          paid_amount = invoice.membership_paid_amount || decimal(invoice.amount)
          deduction = refund_deduction(months, refunded, paid_amount)
          delta = document['status'] == 'revoked' ? decimal(0) : months - deduction
          entry!(document, source_key: source_key(invoice), action: 'application', action_key: 'applied',
            streak_id: streak, invoice_id: invoice.id, months: months, balance_delta: delta,
            paid_amount: paid_amount, currency: invoice.membership_paid_currency,
            refunded_amount: refunded, deducted_months: deduction, occurred_at: at,
            coverage_start: before[id] ? Time.at(before[id].to_r / 1000) : at,
            coverage_end: Time.at(document['expirationTime'].to_r / 1000))
          write_balance!(document, balance(document) + delta,
            streak: document['status'] == 'revoked' ? document['continuous_paid_membership_streak_id'] : streak)
        end
        invoice.update!(membership_paid_applied_at: at, membership_paid_recipient_ids: recipients,
          membership_paid_source_key: source_key(invoice), membership_paid_amount: invoice.membership_paid_amount || decimal(invoice.amount), settled_at: at)
        after_commit { resource.send_renewal_slack_message }
        true
      end
    end

    def recipients_for(invoice, resource)
      if resource.is_a?(Group)
        (resource.household_member_ids + [resource.member&.id]).compact.uniq
      elsif invoice.plan_id.to_s.include?('household') && resource.household_role == :primary
        group = Group.find_by(groupName: resource.id.to_s)
        ([resource.id] + Array(group&.household_member_ids)).uniq
      else
        [resource.id]
      end
    end

    def refund!(invoice_id:, refund_id:, amount:, currency: 'USD', origin: 'offline', at: Time.current)
      amount = decimal(amount)
      raise Error::UnprocessableEntity.new('A confirmed refund identity and positive amount are required.') if refund_id.to_s.strip.empty? || !amount.finite? || amount <= 0
      transaction do
        invoice = Invoice.find(invoice_id)
        raise Error::NotFound.new unless invoice
        raise Error::UnprocessableEntity.new('Refund currency does not match the payment.') unless currency == invoice.membership_paid_currency
        identity = "#{origin}:#{refund_id}"
        previous = invoice.membership_paid_refunds.find { |r| r['id'] == identity }
        if previous
          raise Error::Conflict.new('This refund identity has a different amount.') unless decimal(previous['amount']) == amount
          Rails.logger.info("[MembershipPaidCredit] duplicate_refund invoice_id=#{invoice.id}")
          next false
        end
        invoice.inc(membership_paid_operation_revision: 1)
        records = invoice.membership_paid_refunds + [{ 'id' => identity, 'amount' => amount.to_s('F'), 'currency' => currency, 'at' => at }]
        total = records.sum { |r| decimal(r['amount']) }
        MembershipPaidCreditEntry.where(invoice_id: invoice.id, source_key: source_key(invoice), action: 'application').each do |credit|
          document = reset_if_due!(document!(credit.member_id, include_deleted: true), at: at)
          deduction = [refund_deduction(credit.months, total, credit.paid_amount), credit.deducted_months].max
          delta = deduction - credit.deducted_months
          same_streak = document['continuous_paid_membership_streak_id'] == credit.streak_id
          entry!(document, source_key: credit.source_key, invoice_id: invoice.id,
            action: 'refund', action_key: identity, streak_id: credit.streak_id,
            months: -delta, balance_delta: same_streak ? -delta : 0, paid_amount: amount,
            currency: currency, occurred_at: at, details: { origin: origin })
          write_balance!(document, balance(document) - delta) if same_streak
          credit.update!(refunded_amount: total, deducted_months: deduction)
        end
        invoice.update!(membership_paid_refunds: records, refunded: total >= (invoice.membership_paid_amount || decimal(invoice.amount)))
        true
      end
    rescue ArgumentError, TypeError
      raise Error::UnprocessableEntity.new('Refund amount must be a decimal amount.')
    end

    def refund_deduction(months, refunded, paid)
      return months if refunded >= paid
      return decimal(0) if refunded <= 0
      months.mult(refunded, 28).div(paid, 28)
    end

    # Historical PayPal/deleted-invoice credits still have stable source IDs.
    # Record a confirmed refund without inventing an invoice or changing expiry.
    def refund_source!(source_key:, refund_id:, amount:, currency: 'USD', at: Time.current)
      amount = decimal(amount)
      unless source_key.to_s.present? && refund_id.to_s.strip.present? && amount.finite? && amount.positive?
        raise Error::UnprocessableEntity.new('A source, stable refund identity, and positive amount are required.')
      end
      transaction do
        credits = MembershipPaidCreditEntry.where(source_key: source_key, action: 'application').to_a
        raise Error::NotFound.new if credits.empty?
        invoice = Invoice.find(credits.first.invoice_id) if credits.first.invoice_id
        if invoice
          next refund!(invoice_id: invoice.id, refund_id: refund_id, amount: amount, currency: currency,
            origin: 'source', at: at)
        end
        credits.each do |credit|
          raise Error::UnprocessableEntity.new('Refund currency does not match the payment.') unless credit.currency == currency
          identity = "source:#{refund_id}"
          previous = MembershipPaidCreditEntry.find_by(source_key: source_key, member_id: credit.member_id,
            action: 'refund', action_key: identity)
          if previous
            raise Error::Conflict.new('This refund identity has a different amount.') unless previous.paid_amount == amount
            Rails.logger.info("[MembershipPaidCredit] duplicate_source_refund member_id=#{credit.member_id}")
            next
          end
          credit.inc(operation_revision: 1)
          total = credit.refunded_amount + amount
          document = reset_if_due!(document!(credit.member_id, include_deleted: true), at: at)
          target = [refund_deduction(credit.months, total, credit.paid_amount), credit.deducted_months].max
          delta = target - credit.deducted_months
          same_streak = document['continuous_paid_membership_streak_id'] == credit.streak_id
          entry!(document, source_key: source_key, action: 'refund', action_key: identity, streak_id: credit.streak_id,
            months: -delta, balance_delta: same_streak ? -delta : 0, paid_amount: amount, currency: currency,
            occurred_at: at, details: { historical_source: true })
          write_balance!(document, balance(document) - delta) if same_streak
          credit.update!(refunded_amount: total, deducted_months: target)
        end
        true
      end
    rescue ArgumentError, TypeError
      raise Error::UnprocessableEntity.new('Refund amount must be a decimal amount.')
    end

    def reverse_invoice!(invoice_id)
      transaction do
        invoice = Invoice.find(invoice_id)
        if invoice.membership_paid_reversed_at && invoice.last_failed_transaction_id == invoice.transaction_id
          Rails.logger.info("[MembershipPaidCredit] duplicate_reversal invoice_id=#{invoice.id}")
          next false
        end
        invoice.inc(membership_paid_operation_revision: 1)
        MembershipPaidCreditEntry.where(invoice_id: invoice.id, source_key: source_key(invoice), action: 'application').each do |credit|
          document = reset_if_due!(document!(credit.member_id, include_deleted: true))
          delta = credit.months - credit.deducted_months
          same_streak = document['continuous_paid_membership_streak_id'] == credit.streak_id
          entry!(document, source_key: credit.source_key, invoice_id: invoice.id, action: 'reversal',
            action_key: 'settlement_declined', streak_id: credit.streak_id, months: -delta,
            balance_delta: same_streak ? -delta : 0, occurred_at: Time.current)
          write_balance!(document, balance(document) - delta) if same_streak
          credit.update!(deducted_months: credit.months)
        end
        invoice.send(:reverse_invoice_operation_without_paid_credit)
        invoice.update!(membership_paid_reversed_at: Time.current, last_failed_transaction_id: invoice.transaction_id)
        true
      end
    end

    def increase!(member_id:, months:, expected_revision:, reason:, actor:)
      unless months.is_a?(Integer) && months >= 0 && expected_revision.is_a?(Integer) && expected_revision >= 0 && reason.is_a?(String) && reason.strip.present? && reason.length <= 2000
        raise Error::UnprocessableEntity.new('Enter a whole number of months, the current revision, and a correction reason.')
      end
      raise Error::Forbidden.new unless actor&.role == 'admin'
      transaction do
        document = document!(member_id)
        raise Error::Conflict.new('Paid membership changed. Refresh and review the current value.') unless document['continuous_paid_membership_revision'].to_i == expected_revision
        if document['status'] == 'revoked' || document['expirationTime'].nil? || expired?(document)
          raise Error::UnprocessableEntity.new('Restore membership eligibility and expiration before increasing paid membership months.')
        end
        raise Error::UnprocessableEntity.new('The proposed value must exceed the current paid balance.') unless months > balance(document)
        updated = write_balance!(document, months)
        entry!(updated, source_key: "admin:#{member_id}:#{expected_revision}", action: 'admin_adjustment',
          action_key: 'increase', months: decimal(months) - balance(document), balance_delta: decimal(months) - balance(document),
          occurred_at: Time.current, details: { actor_id: actor.id.to_s, reason: reason.strip,
            old_balance: balance(document).to_s('F'), new_balance: months.to_s })
        log = Service::AuditLogger.log(log_type: 'member', event_type: 'continuous_paid_membership_months_increased',
          resource_type: 'Member', resource_id: document['_id'], actor: actor,
          subject: AuditSubject.new(document['_id'], "#{document['firstname']} #{document['lastname']}"),
          before_snapshot: { balance: balance(document).to_s('F') }, after_snapshot: { balance: months.to_s },
          message_details: reason.strip)
        raise Error::UnprocessableEntity.new('Could not record the correction audit. No changes were saved.') unless log
        representation(updated)
      end
    end

    def write_balance!(document, value, streak: nil, extra: {})
      value = [decimal(value), decimal(0)].max
      revision = document['continuous_paid_membership_revision'].to_i
      selector = { _id: document['_id'], expirationTime: document['expirationTime'], status: document['status'],
        continuous_paid_membership_streak_id: document['continuous_paid_membership_streak_id'],
        continuous_paid_membership_revision: revision.zero? ? { '$in' => [nil, 0] } : revision }
      fields = { continuous_paid_membership_balance: BSON::Decimal128.new(value.to_s('F')),
        continuous_paid_membership_months: value.floor, continuous_paid_membership_revision: revision + 1,
        continuous_paid_membership_streak_id: streak || document['continuous_paid_membership_streak_id'] || SecureRandom.uuid }.merge(extra)
      updated = Member.collection.find_one_and_update(selector, { '$set' => fields }, { return_document: :after }.merge(session_options))
      raise Error::Conflict.new('Paid membership changed. Refresh and retry.') unless updated
      updated
    end

    def entry!(document, **attributes)
      MembershipPaidCreditEntry.create!({ member_id: document['_id'],
        streak_id: document['continuous_paid_membership_streak_id'] || "legacy:#{document['_id']}" }.merge(attributes))
    end
  end
end
