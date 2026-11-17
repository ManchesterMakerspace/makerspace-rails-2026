namespace :membership do
  desc 'Create additive paid membership ledger/backfill and expiration-sweep indexes (no data changes)'
  task ensure_paid_indexes: :environment do
    [MembershipPaidCreditEntry, MembershipPaidBackfillReport].each(&:create_indexes)
    Member.collection.indexes.create_one(expirationTime: 1, continuous_paid_membership_balance: 1)
  end

  desc 'Backfill paid months: [dry_run|apply,run_id,limit]; default dry_run, resume using returned run_id'
  task :backfill_paid_months, [:mode, :run_id, :limit] => :environment do |_task, args|
    result = MembershipPaidBackfill.run!(mode: args[:mode].presence || 'dry_run',
      run_id: args[:run_id], limit: args[:limit].presence)
    puts JSON.pretty_generate(result)
  end

  desc 'Record a confirmed offline membership refund (does not change expiration or send money)'
  task :record_paid_refund, [:invoice_id, :refund_id, :amount, :currency] => :environment do |_task, args|
    MembershipPaidCredit.refund!(invoice_id: args[:invoice_id], refund_id: args[:refund_id],
      amount: args[:amount], currency: args[:currency].presence || 'USD', origin: 'offline')
  end

  desc 'Reconcile confirmed Braintree refunds for one membership invoice (read-only provider requests)'
  task :reconcile_paid_refunds, [:invoice_id] => :environment do |_task, args|
    invoice = Invoice.find(args[:invoice_id])
    raise 'A paid membership invoice with a Braintree transaction is required' unless invoice &&
      %w[member household].include?(invoice.resource_class) && invoice.transaction_id.present?
    BraintreeService::Transaction.reconcile_membership_refunds(Service::BraintreeGateway.connect_gateway, invoice)
  end

  desc 'Record a confirmed refund against a historical source identity without an invoice'
  task :record_paid_source_refund, [:source_key, :refund_id, :amount, :currency] => :environment do |_task, args|
    MembershipPaidCredit.refund_source!(source_key: args[:source_key], refund_id: args[:refund_id],
      amount: args[:amount], currency: args[:currency].presence || 'USD')
  end
end
