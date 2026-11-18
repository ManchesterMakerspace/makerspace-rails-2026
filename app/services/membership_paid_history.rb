require 'time'

# Raw historical reader: Payment#after_initialize changes member records, so it
# must never instantiate legacy Payments. No amount-to-current-price inference.
class MembershipPaidHistory
  LEGACY_DURATION_MONTHS = {
    '1-month Individual Membership 1mo-Stnd' => 1, '1-month Subscription' => 1,
    'Subscription Membership Sub-Stnd-Membership' => 1, '1-month Subscription Sub-Stnd-Membership' => 1,
    '1mo-Sub' => 1, '1mo-Stnd' => 1, 'Sub-Stnd-Membership' => 1,
    '1-month Discount Subscription' => 1, '1mo-Sub-SMS' => 1, '1mo-Stnd-SMS' => 1,
    '3-month Subscription' => 3, '3mo-Sub' => 3, '3-month Discount Subscription' => 3,
    '3mo-Sub-SMS' => 3, '6mo-Sub' => 6, '6mo-Sub-SMS' => 6, '12mo-Sub' => 12, '12mo-Sub-SMS' => 12
  }.freeze

  attr_reader :sources, :issues, :balance, :streak_id

  def initialize(document, cutoff:)
    @document, @cutoff = document, cutoff
    @sources, @issues, @events = {}, [], []
    @balance = BigDecimal('0')
    @cohort = 0
    @streak_id = document['continuous_paid_membership_streak_id'] || SecureRandom.uuid
  end

  def analyze
    @audits = AuditLog.collection.find({ '$or' => [{ subject_id: @document['_id'] },
      { resource_type: 'Member', resource_id: @document['_id'] }] }, options).sort(created_at: 1).to_a
    @live = MembershipPaidCreditEntry.where(member_id: @document['_id']).asc(:created_at).to_a
    invoices = Invoice.collection.find({ '$or' => [
      { resource_class: 'member', resource_id: @document['_id'].to_s },
      { membership_paid_recipient_ids: @document['_id'] }, { resource_class: 'household' },
      { resource_class: 'member', plan_id: /household/i }
    ] }, options).to_a
    # A deleted invoice is usable only if an audit retained its full applied contract.
    @audits.each do |audit|
      snapshot = audit['after_snapshot'] || {}
      if audit['resource_type'] == 'Invoice' && snapshot['settled_at'] && snapshot['quantity'] && snapshot['resource_class']
        invoices << snapshot.merge('_id' => audit['resource_id']) unless invoices.any? { |i| i['_id'] == audit['resource_id'] }
      end
    end
    seen_transactions = invoices.filter_map { |i| i['transaction_id'].presence }.to_set
    invoices.each { |invoice| add_invoice(invoice) }
    legacy_payments(seen_transactions)
    add_audit_transitions
    add_live_events
    replay
    issues << 'no_identifiable_paid_history' if sources.empty? && @document['expirationTime'].to_i > Time.current.to_i * 1000
    self
  end

  def estimated?
    issues.any? || sources.values.any? { |s| s[:estimated] }
  end

  def report
    { months: [balance, 0].max.floor, balance: [balance, 0].max.to_s('F'), estimated: estimated?,
      issues: issues.uniq, sources: sources.values.map { |s| { source_key: s[:source_key],
        months: s[:months].to_s('F'), streak_id: s[:streak_id], estimated: s[:estimated] } } }
  end

  private

  def options
    MembershipPaidCredit.session_options
  end

  def time(value)
    return value.to_time if value.respond_to?(:to_time)
    Time.parse(value.to_s) if value.present?
  rescue ArgumentError
    nil
  end

  def decimal(value)
    MembershipPaidCredit.decimal(value)
  end

  def household_recipient?(invoice)
    recipients = Array(invoice['membership_paid_recipient_ids']).map(&:to_s)
    return recipients.include?(@document['_id'].to_s) if recipients.any?
    return true if invoice['resource_class'] == 'member' && invoice['resource_id'] == @document['_id'].to_s
    if invoice['resource_class'] == 'member'
      # This invoice form stores the primary's member ID directly. Historical
      # evidence can identify a former secondary even if the group was deleted.
      key = invoice['resource_id'].to_s
    else
      group_id = invoice['resource_id']
      group = Group.collection.find({ _id: BSON::ObjectId.from_string(group_id) }, options).first if BSON::ObjectId.legal?(group_id.to_s)
      key = group&.[]('groupName').to_s
    end
    return false if key.blank?
    return true if key == @document['_id'].to_s
    applied_at = time(invoice['settled_at'])
    evidence = @audits.select { |a| a['created_at'] && a['created_at'] <= applied_at }.reverse.find do |audit|
      audit.dig('after_snapshot', 'groupName').present? || audit.dig('field_changes', 'groupName')
    end
    historical_key = evidence&.dig('field_changes', 'groupName')&.last || evidence&.dig('after_snapshot', 'groupName')
    historical_key.to_s == key
  end

  def add_invoice(invoice)
    return unless %w[member household].include?(invoice['resource_class']) && invoice.fetch('operation', 'renew=') == 'renew='
    at = time(invoice['settled_at'])
    return unless at && at <= @cutoff
    household = invoice['resource_class'] == 'household' || invoice['plan_id'].to_s.match?(/household/i)
    return if household && !household_recipient?(invoice)
    months, paid = decimal(invoice['quantity']), decimal(invoice['membership_paid_amount'] || invoice['amount'])
    return unless months.positive? && paid.positive?
    source = invoice['membership_paid_source_key'].presence ||
      (invoice['transaction_id'].present? ? "braintree:#{invoice['transaction_id']}" : "invoice:#{invoice['_id']}")
    existing = @live.find { |entry| entry.source_key == source && entry.action == 'application' }
    months, paid = existing.months, existing.paid_amount if existing
    coverage = @audits.find do |audit|
      audit['created_at'] && (audit['created_at'] - at).abs <= 60 &&
        audit.dig('field_changes', 'expirationTime') &&
        (audit['slack_message'].to_s.include?(invoice['_id'].to_s) || audit.dig('after_snapshot', 'transaction_id') == invoice['transaction_id'])
    end
    transition = coverage&.dig('field_changes', 'expirationTime')
    start = existing&.coverage_start || (transition&.first && Time.at(transition.first.to_r / 1000)) || at
    finish = existing&.coverage_end || (transition&.last && Time.at(transition.last.to_r / 1000)) || at + months.to_i.months
    uncertain = !existing && !coverage
    issues << "household_recipients_incomplete:#{invoice['_id']}" if household && Array(invoice['membership_paid_recipient_ids']).empty?
    add_source(source_key: source, invoice_id: invoice['_id'], at: at, months: months, paid_amount: paid,
      currency: invoice['membership_paid_currency'] || 'USD', coverage_start: start, coverage_end: finish,
      estimated: uncertain, existing: existing, refunds: Array(invoice['membership_paid_refunds']), legacy_refunded: invoice['refunded'],
      zero_credit: existing&.streak_id&.start_with?('revoked:'))
  rescue ArgumentError, TypeError
    issues << "invalid_invoice:#{invoice['_id']}"
  end

  def legacy_payments(seen_transactions)
    Payment.collection.find({ member_id: @document['_id'] }, options).each do |payment|
      next if payment['test'] || seen_transactions.include?(payment['txn_id'])
      next unless %w[completed processed].include?(payment['status'].to_s.downcase)
      next unless %w[web_accept subscr_payment recurring_payment cart].include?(payment['txn_type'].to_s)
      at = time(payment['payment_date'])
      next unless at && at <= @cutoff
      months = LEGACY_DURATION_MONTHS[payment['product']] || LEGACY_DURATION_MONTHS[payment['plan_id']]
      unless months
        issues << "unmapped_legacy_product:#{payment['_id']}" unless payment['product'].to_s.match?(/rental|plot|locker|shelf|donat|fee/i)
        next
      end
      next unless decimal(payment['amount']).positive?
      identity = payment['txn_id'].presence
      source = identity ? "paypal:#{identity}" : "legacy-payment:#{payment['_id']}"
      add_source(source_key: source, at: at, months: decimal(months), paid_amount: decimal(payment['amount']),
        currency: payment['currency'].presence || 'USD', coverage_start: at, coverage_end: at + months.months,
        estimated: true, refunds: [], legacy_refunded: false)
      issues << "legacy_source_requires_refund_review:#{source}"
    end
  end

  def add_source(**source)
    key = source[:source_key]
    return if sources.key?(key)
    source[:deducted_months] = decimal(0)
    source[:refunded_amount] = decimal(0)
    sources[key] = source
    @events << { type: :application, at: source[:at], source: source }
    source[:refunds].each do |refund|
      refunded_at = time(refund['at'])
      issues << "refund_time_unknown:#{key}" unless refunded_at
      @events << { type: :refund, at: refunded_at || @cutoff, source: source, amount: decimal(refund['amount']) }
    end
    if source[:legacy_refunded] && source[:refunds].empty?
      @events << { type: :refund, at: @cutoff, source: source, amount: source[:paid_amount] }
      issues << "legacy_refund_identity_unknown:#{key}"
    end
  end

  def add_audit_transitions
    @audits.each do |audit|
      at = audit['created_at']
      next unless at
      changes = audit['field_changes'] || {}
      expiry = changes['expirationTime']
      revoked = changes['status']&.last == 'revoked' || audit['event_type'] == 'membership_revoked'
      @events << { type: :transition, at: at, old_expiry: expiry&.first, expiry: expiry&.last, revoked: revoked } if expiry || revoked
      if audit['event_type'] == 'braintree_payment_unmatched'
        issues << "unresolved_payment_audit:#{audit['_id']}"
      end
    end
  end

  def add_live_events
    @live.each do |entry|
      if entry.action == 'application' && !sources.key?(entry.source_key)
        add_source(source_key: entry.source_key, invoice_id: entry.invoice_id, at: entry.occurred_at,
          months: entry.months, paid_amount: entry.paid_amount, currency: entry.currency,
          coverage_start: entry.coverage_start, coverage_end: entry.coverage_end, estimated: entry.estimated,
          existing: entry, refunds: [], legacy_refunded: false,
          zero_credit: entry.streak_id.start_with?('revoked:'))
      elsif entry.action == 'reset'
        @events << { type: :reset, at: entry.occurred_at }
      elsif %w[refund reversal].include?(entry.action)
        source = sources[entry.source_key]
        next unless source
        # Invoice refund records already supply amount and timestamp. Live credit
        # sources without historical invoices use their recorded month deduction.
        next if entry.action == 'refund' && source[:refunds].any?
        @events << { type: :deduction, at: entry.occurred_at, source: source, months: -entry.months }
      end
    end
  end

  def reset
    @balance = decimal(0)
    @cohort += 1
  end

  def replay
    expiry = nil
    ranks = { transition: 0, reset: 0, application: 1, refund: 2, deduction: 2 }
    @events.sort_by { |event| [event[:at], ranks[event[:type]]] }.each do |event|
      case event[:type]
      when :transition
        old = event[:old_expiry]
        reset if event[:revoked] || (old && event[:at].to_r * 1000 >= old.to_i + MembershipPaidCredit::GRACE_SECONDS * 1000)
        expiry = Time.at(event[:expiry].to_r / 1000) if event[:expiry]
      when :reset
        reset
      when :application
        source = event[:source]
        if expiry && event[:at] >= expiry + MembershipPaidCredit::GRACE_SECONDS
          if Member::ACTIVE_MEMBERSHIP_STATUSES.include?(@document['status']) && @document['expirationTime'].to_i > Time.current.to_i * 1000
            issues << 'inferred_continuity_across_missing_history'
          else
            reset
          end
        end
        # Live application entries use a dedicated revoked streak when the
        # payment extended duration but deliberately credited no paid months.
        # Keep it outside every credited cohort, even after status restoration.
        source[:cohort] = source[:zero_credit] ? nil : @cohort
        # A held payment may have been refunded before its first-fob release.
        # Its refund event already set deducted_months without a cohort to debit.
        @balance += source[:months] - source[:deducted_months] unless source[:zero_credit]
        expiry = [expiry, source[:coverage_end]].compact.max
      when :refund, :deduction
        source = event[:source]
        if event[:type] == :refund
          source[:refunded_amount] += event[:amount]
          target = MembershipPaidCredit.refund_deduction(source[:months], source[:refunded_amount], source[:paid_amount])
        else
          target = [source[:deducted_months] + event[:months], source[:months]].min
        end
        @balance -= target - source[:deducted_months] if source[:cohort] == @cohort
        source[:deducted_months] = target
      end
    end
    if @document['status'] == 'revoked' || MembershipPaidCredit.expired?(@document) || @document['expirationTime'].nil?
      reset
    end
    sources.each_value do |source|
      source[:streak_id] = source[:existing]&.streak_id ||
        (source[:cohort] == @cohort ? streak_id : "history:#{@document['_id']}:#{source[:cohort]}")
    end
    @balance = [@balance, decimal(0)].max
  end
end
