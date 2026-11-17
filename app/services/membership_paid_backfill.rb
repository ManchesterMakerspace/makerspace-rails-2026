class MembershipPaidBackfill
  def self.run!(mode: 'dry_run', run_id: nil, limit: nil)
    raise ArgumentError, 'Mode must be dry_run or apply' unless %w[dry_run apply].include?(mode)
    limit = Integer(limit) if limit
    raise ArgumentError, 'Limit must be a positive member count' if limit && limit <= 0
    run = run_id.present? ? MembershipPaidBackfillRun.find(run_id) : MembershipPaidBackfillRun.create!(cutoff: Time.current, mode: mode)
    raise ArgumentError, 'Unknown backfill run' unless run
    run.update!(mode: mode, cursor: nil, completed_at: nil) if run.mode != mode
    retry_ids = MembershipPaidBackfillReport.where(run_id: run.id, :status.in => %w[conflicted failed]).pluck(:member_id)
    selector = { merged_at: nil }
    selector['$or'] = [{ _id: { '$gt' => run.cursor } }, { _id: { '$in' => retry_ids } }] if run.cursor
    processed = 0
    Member.collection.find(selector).sort(_id: 1).each do |snapshot|
      break if limit && processed >= limit
      report = MembershipPaidBackfillReport.find_or_initialize_by(run_id: run.id, member_id: snapshot['_id'])
      next if report.mode == mode && %w[initialized estimated skipped].include?(report.status)
      begin
        if mode == 'apply'
          MembershipPaidCredit.transaction do
            document = MembershipPaidCredit.document!(snapshot['_id'])
            raise Error::Conflict.new('Member changed during backfill analysis') unless
              document['continuous_paid_membership_revision'].to_i == snapshot['continuous_paid_membership_revision'].to_i
            current_report = MembershipPaidBackfillReport.find_or_initialize_by(run_id: run.id, member_id: snapshot['_id'])
            process_member(document, run, current_report, apply: true)
          end
        else
          process_member(snapshot, run, report, apply: false)
        end
      rescue Error::Conflict => error
        report.update!(mode: mode, status: 'conflicted', issues: [error.message])
      rescue => error
        report.update!(mode: mode, status: 'failed', issues: ["#{error.class}: #{error.message}"])
        Rails.logger.error("[MembershipPaidBackfill] failed member_id=#{snapshot['_id']} type=#{error.class}")
      end
      run.update!(cursor: [run.cursor, snapshot['_id']].compact.max)
      processed += 1
    end
    counts = %w[initialized estimated skipped conflicted failed].to_h do |status|
      [status, MembershipPaidBackfillReport.where(run_id: run.id, mode: mode, status: status).count]
    end
    remaining = Member.collection.find(merged_at: nil, :_id => { '$gt' => run.cursor }).limit(1).first if run.cursor
    run.update!(counts: counts, completed_at: remaining || counts['conflicted'].positive? || counts['failed'].positive? ? nil : Time.current)
    { run_id: run.id.to_s, cutoff: run.cutoff.iso8601, mode: mode, counts: counts,
      report_collection: 'membership_paid_backfill_reports' }
  end

  def self.process_member(document, run, report, apply:)
    if document['continuous_paid_membership_backfilled_at'] ||
        MembershipPaidCreditEntry.where(member_id: document['_id'], action: 'admin_adjustment').exists?
      report.update!(mode: run.mode, status: 'skipped', issues: ['Already initialized or corrected by an administrator'])
      return
    end
    history = MembershipPaidHistory.new(document, cutoff: run.cutoff).analyze
    if apply
      history.sources.each_value do |source|
        next if source[:existing]
        # Lock source invoices against refunds that arrive while this baseline is
        # being committed, including refunds with no live member credit yet.
        Invoice.where(id: source[:invoice_id]).inc(membership_paid_operation_revision: 1) if source[:invoice_id]
        MembershipPaidCredit.entry!(document, source_key: source[:source_key], action: 'application', action_key: 'applied',
          invoice_id: source[:invoice_id], streak_id: source[:streak_id], months: source[:months],
          balance_delta: source[:months] - source[:deducted_months], paid_amount: source[:paid_amount],
          currency: source[:currency], refunded_amount: source[:refunded_amount], deducted_months: source[:deducted_months],
          occurred_at: source[:at], coverage_start: source[:coverage_start], coverage_end: source[:coverage_end],
          estimated: source[:estimated], details: { backfill_run_id: run.id.to_s, cutoff: run.cutoff })
      end
      document = MembershipPaidCredit.write_balance!(document, history.balance, streak: history.streak_id,
        extra: { continuous_paid_membership_estimated: history.estimated?, continuous_paid_membership_backfilled_at: Time.current,
          continuous_paid_membership_backfill_run_id: run.id.to_s })
    end
    report.update!({ mode: run.mode, status: history.estimated? ? 'estimated' : 'initialized',
      revision: document['continuous_paid_membership_revision'].to_i }.merge(history.report))
  end
end
