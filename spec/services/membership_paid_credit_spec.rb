require 'rails_helper'

RSpec.describe MembershipPaidCredit, requires_transactions: true do
  before(:all) { MembershipPaidCreditEntry.create_indexes }
  let(:member) { create(:member, expirationTime: 1.month.from_now.to_i * 1000) }

  before do
    ActiveJob::Base.queue_adapter = :test
    allow(Service::SlackConnector).to receive(:send_slack_message)
    allow(Service::SlackConnector).to receive(:enque_message)
  end

  def invoice_for(person = member, **attributes)
    create(:invoice, member: person, resource_id: person.id.to_s, resource_class: 'member',
      amount: 120, quantity: 12, plan_id: nil, **attributes)
  end

  def apply(person = member, **attributes)
    create(:card, member: person) if person.access_cards.empty?
    invoice_for(person, **attributes).tap(&:settle_invoice)
  end

  def refund(invoice, id, amount)
    described_class.refund!(invoice_id: invoice.id, refund_id: id, amount: amount)
  end

  it 'credits prepaid terms only once and persists the application, recipients, and expiration' do
    invoice = apply
    expiry = member.reload.expirationTime
    expect(described_class.read(member.id)[:continuousPaidMembershipMonths]).to eq(12)
    expect(invoice.reload.membership_paid_recipient_ids).to eq([member.id])
    invoice.settle_invoice
    expect(member.reload.expirationTime).to eq(expiry)
    expect(MembershipPaidCreditEntry.where(action: 'application').count).to eq(1)
  end

  it 'holds a payment until first fob issuance, then credits it exactly once' do
    invoice = invoice_for(member, transaction_id: 'held')
    invoice.settle_invoice
    expect(described_class.read(member.id)[:continuousPaidMembershipMonths]).to eq(0)
    create(:card, member: member)
    expect(described_class.read(member.id)[:continuousPaidMembershipMonths]).to eq(12)
    expect(invoice.reload.membership_paid_applied_at).to be_present
  end

  it 'credits confirmed cash/check invoices without a provider transaction' do
    create(:card, member: member)
    invoice = invoice_for(member, quantity: 2)
    invoice.submit_for_settlement
    expect(described_class.read(member.id)[:continuousPaidMembershipMonths]).to eq(2)
    expect(invoice.reload.membership_paid_source_key).to eq("invoice:#{invoice.id}")
  end

  it 'releases a confirmed cash/check payment at the first fob even without a transaction ID' do
    invoice = invoice_for
    invoice.submit_for_settlement
    expect(invoice.reload.membership_paid_confirmed_at).to be_present
    expect(invoice.settled_at).to be_nil
    expect(described_class.read(member.id)[:continuousPaidMembershipMonths]).to eq(0)
    create(:card, member: member)
    expect(invoice.reload.settled_at).to be_present
    expect(described_class.read(member.id)[:continuousPaidMembershipMonths]).to eq(12)
  end

  it 'retains fractional months and uses cumulative partial refunds without changing expiration' do
    invoice = apply
    expiry = member.reload.expirationTime
    refund(invoice, 'one', '1')
    refund(invoice, 'two', '2')
    refund(invoice, 'two', '2')
    expect(described_class.balance(described_class.document!(member.id))).to eq(BigDecimal('11.7'))
    expect(described_class.read(member.id)[:continuousPaidMembershipMonths]).to eq(11)
    refund(invoice, 'rest', '117')
    expect(described_class.read(member.id)[:continuousPaidMembershipMonths]).to eq(0)
    expect(member.reload.expirationTime).to eq(expiry)
    expect(MembershipPaidCreditEntry.where(action: 'refund').count).to eq(3)
  end

  it 'does not deduct a refund request or a fully refunded held payment' do
    invoice = invoice_for(member, transaction_id: 'held')
    invoice.set_refund_requested
    expect(described_class.read(member.id)[:continuousPaidMembershipMonths]).to eq(0)
    refund(invoice, 'full', '120')
    create(:card, member: member)
    expect(invoice.reload.settled_at).to be_nil
    expect(member.reload.continuous_paid_membership_balance).to eq(0)
  end

  it 'reverses applied credit and duration once when settlement is declined' do
    invoice = apply(member, transaction_id: 'declined')
    invoice.reverse_settlement
    expiry = member.reload.expirationTime
    invoice.reverse_settlement
    expect(member.reload.expirationTime).to eq(expiry)
    expect(described_class.read(member.id)[:continuousPaidMembershipMonths]).to eq(0)
    expect(MembershipPaidCreditEntry.where(action: 'reversal').count).to eq(1)
  end

  it 'applies a new charge on the same invoice after the previous attempt was reversed' do
    invoice = apply(member, transaction_id: 'declined-attempt')
    invoice.reverse_settlement
    expect(described_class.read(member.id)[:continuousPaidMembershipMonths]).to eq(0)
    invoice.reload.update!(transaction_id: 'successful-retry', membership_paid_amount: BigDecimal('120'))
    invoice.settle_invoice
    expect(described_class.read(member.id)[:continuousPaidMembershipMonths]).to eq(12)
    expect(MembershipPaidCreditEntry.where(invoice_id: invoice.id, action: 'application').count).to eq(2)
    expect(MembershipPaidCreditEntry.where(invoice_id: invoice.id, action: 'reversal').count).to eq(1)
    expect(invoice.reload.membership_paid_source_key).to eq('braintree:successful-retry')
    invoice.settle_invoice
    expect(MembershipPaidCreditEntry.where(invoice_id: invoice.id, action: 'application').count).to eq(2)
    refund(invoice, 'retry-half-refund', 60)
    expect(described_class.read(member.id)[:continuousPaidMembershipMonths]).to eq(6)
    expect(MembershipPaidCreditEntry.where(source_key: 'braintree:declined-attempt', action: 'refund').count).to eq(0)
    invoice.reverse_settlement
    expect(described_class.read(member.id)[:continuousPaidMembershipMonths]).to eq(0)
    expect(MembershipPaidCreditEntry.where(source_key: 'braintree:declined-attempt', action: 'reversal').count).to eq(1)
    expect(MembershipPaidCreditEntry.where(source_key: 'braintree:successful-retry', action: 'reversal').count).to eq(1)
  end

  it 'retries an already confirmed cash receipt after accounting fails' do
    create(:card, member: member)
    invoice = invoice_for
    allow(described_class).to receive(:apply_invoice!).and_raise(Error::Conflict.new('retry'))
    expect { invoice.submit_for_settlement }.to raise_error(Error::Conflict)
    expect(invoice.reload.membership_paid_confirmed_at).to be_present
    expect(invoice.settled_at).to be_nil
    expect(described_class.read(member.id)[:continuousPaidMembershipMonths]).to eq(0)
    allow(described_class).to receive(:apply_invoice!).and_call_original
    invoice.submit_for_settlement
    expect(described_class.read(member.id)[:continuousPaidMembershipMonths]).to eq(12)
  end

  it 'does not credit an unpaid renewal and resets before a late extension' do
    apply
    member.reload.update!(renew: 1)
    expect(described_class.read(member.id)[:continuousPaidMembershipMonths]).to eq(12)
    member.set(expirationTime: 241.hours.ago.to_i * 1000)
    member.reload.update!(renew: 1)
    expect(described_class.read(member.id)[:continuousPaidMembershipMonths]).to eq(0)
  end

  it 'reads zero exactly at 240 elapsed hours, including across daylight saving changes' do
    apply
    expiry = Time.utc(2026, 10, 31, 12)
    member.set(expirationTime: expiry.to_i * 1000)
    document = described_class.document!(member.id)
    expect(described_class.representation(document, at: expiry + 240.hours - 0.001)[:continuousPaidMembershipMonths]).to eq(12)
    expect(described_class.representation(document, at: expiry + 240.hours)[:continuousPaidMembershipMonths]).to eq(0)
    expect(described_class.sweep!(at: expiry + 240.hours)).to eq(1)
    expect(described_class.sweep!(at: expiry + 240.hours)).to eq(0)
  end

  it 'preserves continuity when an unpaid extension precedes the boundary' do
    apply
    member.set(expirationTime: (240.hours.ago.to_r * 1000).floor + 1000)
    member.reload.update!(renew: 1)
    expect(described_class.read(member.id)[:continuousPaidMembershipMonths]).to eq(12)
  end

  it 'records old-streak refunds without deducting a new paid streak' do
    old_invoice = apply
    member.set(expirationTime: 241.hours.ago.to_i * 1000)
    apply(member, quantity: 1, amount: 10)
    refund(old_invoice, 'old-refund', 120)
    expect(described_class.read(member.id)[:continuousPaidMembershipMonths]).to eq(1)
    expect(MembershipPaidCreditEntry.where(action: 'refund').first.balance_delta).to eq(0)
  end

  it 'resets on revocation, preserves on suspension, and never restores credit on restoration' do
    apply
    member.reload.update!(status: 'suspended')
    expect(described_class.read(member.id)[:continuousPaidMembershipMonths]).to eq(12)
    member.reload.update!(status: 'revoked')
    expect(member.reload.continuous_paid_membership_balance).to eq(0)
    member.update!(status: 'activeMember')
    expect(described_class.read(member.id)[:continuousPaidMembershipMonths]).to eq(0)
  end

  it 'rolls back expiration, entries, balance, and invoice markers after an interrupted application' do
    create(:card, member: member)
    invoice = invoice_for
    expiry = member.reload.expirationTime
    allow(MembershipPaidCreditEntry).to receive(:create!).and_raise('interrupted')
    expect { invoice.settle_invoice }.to raise_error('interrupted')
    expect(member.reload.expirationTime).to eq(expiry)
    expect(member.continuous_paid_membership_months).to eq(0)
    expect(invoice.reload.settled_at).to be_nil
    expect(invoice.membership_paid_applied_at).to be_nil
  end

  it 'rolls an admin increase back when its audit cannot be persisted' do
    actor = create(:member, :admin)
    allow(Service::AuditLogger).to receive(:log).and_return(nil)
    expect do
      described_class.increase!(member_id: member.id, months: 3, expected_revision: 0, reason: 'Missing history', actor: actor)
    end.to raise_error(Error::UnprocessableEntity, /audit/)
    expect(member.reload.continuous_paid_membership_months).to eq(0)
    expect(MembershipPaidCreditEntry.where(action: 'admin_adjustment')).not_to exist
  end

  it 'atomically records an admin correction and rejects stale revisions' do
    actor = create(:member, :admin)
    result = described_class.increase!(member_id: member.id, months: 3, expected_revision: 0, reason: 'Missing history', actor: actor)
    expect(result[:continuousPaidMembershipMonths]).to eq(3)
    expect(AuditLog.where(event_type: 'continuous_paid_membership_months_increased').first.actor_id).to eq(actor.id)
    expect do
      described_class.increase!(member_id: member.id, months: 4, expected_revision: 0, reason: 'Stale', actor: actor)
    end.to raise_error(Error::Conflict)
  end

  it 'never executes accounting writes when transaction support is unavailable', requires_transactions: false do
    session = double('session', in_transaction?: false, end_session: nil)
    allow(Member).to receive(:with_session).and_yield(session)
    allow(session).to receive(:start_transaction).and_raise(Mongo::Error::TransactionsNotSupported.new('standalone'))
    expect { described_class.transaction { raise 'unsafe write' } }.to raise_error(Error::UnprocessableEntity, /replica set/)
    expect(described_class.active?).to be(false)
  end

  it 'credits the applied household roster and refunds those recipients after the roster changes' do
    create(:card, member: member)
    invoice = invoice_for(member, plan_id: 'household-membership-one-month-recurring', quantity: 2)
    member.update!(groupName: member.id.to_s)
    group = Group.create!(groupName: member.id.to_s, groupRep: member.fullname, expiry: member.expirationTime)
    secondary = create(:member)
    group.add_subordinate(secondary)
    invoice.settle_invoice
    expect([member, secondary].map { |m| described_class.read(m.id)[:continuousPaidMembershipMonths] }).to eq([2, 2])
    group.remove_subordinate(secondary.reload)
    newcomer = create(:member)
    group.reload.add_subordinate(newcomer)
    expect(described_class.read(newcomer.id)[:continuousPaidMembershipMonths]).to eq(0)
    refund(invoice, 'household-refund', 120)
    expect([member, secondary, newcomer].map { |m| described_class.read(m.id)[:continuousPaidMembershipMonths] }).to eq([0, 0, 0])
    expect(invoice.reload.membership_paid_recipient_ids).to match_array([member.id, secondary.id])
  end

  it 'supports invoices addressed directly to the household Group resource' do
    group = create(:group, member: member)
    invoice = create(:invoice, member: member, resource_class: 'household', resource_id: group.id.to_s, quantity: 6, amount: 300, plan_id: nil)
    invoice.settle_invoice
    expect(described_class.read(member.id)[:continuousPaidMembershipMonths]).to eq(6)
    expect(member.reload.expirationTime).to eq(group.reload.expiry)
  end

  it 'serializes concurrent duplicate processing with a real transaction retry' do
    create(:card, member: member)
    invoice = invoice_for
    start, ready = Queue.new, Queue.new
    threads = 2.times.map do
      Thread.new { ready << true; start.pop; Invoice.find(invoice.id).settle_invoice }
    end
    2.times { ready.pop }; 2.times { start << true }
    threads.each(&:value)
    expect(described_class.read(member.id)[:continuousPaidMembershipMonths]).to eq(12)
    expect(MembershipPaidCreditEntry.where(action: 'application').count).to eq(1)
  end

  it 'serializes separate concurrent payments without losing either credit' do
    create(:card, member: member)
    invoices = [invoice_for(member, transaction_id: 'concurrent-one'), invoice_for(member, transaction_id: 'concurrent-two')]
    start, ready = Queue.new, Queue.new
    threads = invoices.map { |invoice| Thread.new { ready << true; start.pop; invoice.settle_invoice } }
    2.times { ready.pop }; 2.times { start << true }
    threads.each(&:value)
    expect(described_class.read(member.id)[:continuousPaidMembershipMonths]).to eq(24)
    expect(MembershipPaidCreditEntry.where(action: 'application').count).to eq(2)
  end

  it 'handles a missing expiration without inventing a deadline or allowing an admin correction' do
    member.set(expirationTime: nil)
    expect(described_class.read(member.id)[:continuousPaidMembershipMonths]).to eq(0)
    expect(described_class.sweep!).to eq(0)
    actor = create(:member, :admin)
    expect do
      described_class.increase!(member_id: member.id, months: 3, expected_revision: 0, reason: 'Missing date', actor: actor)
    end.to raise_error(Error::UnprocessableEntity, /eligibility/)
  end

  it 'does not invoke a mutating member initialization callback while auditing a correction' do
    group = create(:group, member: member, expiry: 1.month.from_now.to_i * 1000)
    secondary = create(:member, groupName: group.groupName, expirationTime: 1.day.from_now.to_i * 1000)
    before = described_class.document!(secondary.id)['expirationTime']
    actor = create(:member, :admin)
    described_class.increase!(member_id: secondary.id, months: 3, expected_revision: 0, reason: 'Verified', actor: actor)
    expect(described_class.document!(secondary.id)['expirationTime']).to eq(before)
  end

  it 'deducts a partial held refund when the original duration is finally applied' do
    invoice = invoice_for(member, transaction_id: 'partial-held')
    refund(invoice, 'half-before-fob', 60)
    create(:card, member: member)
    expect(described_class.read(member.id)[:continuousPaidMembershipMonths]).to eq(6)
    expect(invoice.reload.settled_at).to be_present
  end

  it 'deduplicates successful portal, settled refund notifications, and provider reconciliation' do
    invoice = apply(member, transaction_id: 'original-charge')
    expiry = member.reload.expirationTime
    provider_refund = double(id: 'provider-refund', refunded_transaction_id: 'original-charge', amount: '60',
      currency_iso_code: 'USD', created_at: Time.current, status: 'settled', invoice: invoice)
    transaction_api = double
    gateway = double(transaction: transaction_api)
    allow(transaction_api).to receive(:refund).with('original-charge').and_return(double(success?: true, transaction: provider_refund))
    allow(BraintreeService::Transaction).to receive(:normalize).with(gateway, provider_refund).and_return(provider_refund)
    BraintreeService::Transaction.refund(gateway, 'original-charge')
    notification = double(transaction: provider_refund, kind: Braintree::WebhookNotification::Kind::TransactionSettled)
    BraintreeService::Notification.send(:process_transaction, notification)
    allow(transaction_api).to receive(:find).with('original-charge').and_return(double(refund_ids: ['provider-refund']))
    allow(transaction_api).to receive(:find).with('provider-refund').and_return(provider_refund)
    BraintreeService::Transaction.reconcile_membership_refunds(gateway, invoice)
    expect(described_class.read(member.id)[:continuousPaidMembershipMonths]).to eq(6)
    expect(MembershipPaidCreditEntry.where(action: 'refund').count).to eq(1)
    expect(member.reload.expirationTime).to eq(expiry)
  end

  it 'serializes a renewal/reset race at the deadline without clearing the new paid streak' do
    apply
    member.set(expirationTime: 240.hours.ago.to_i * 1000)
    invoice = invoice_for(member, transaction_id: 'after-lapse', quantity: 1)
    start, ready = Queue.new, Queue.new
    threads = [Thread.new { ready << true; start.pop; invoice.settle_invoice },
      Thread.new { ready << true; start.pop; described_class.sweep! }]
    2.times { ready.pop }; 2.times { start << true }
    threads.each(&:value)
    expect(described_class.read(member.id)[:continuousPaidMembershipMonths]).to eq(1)
  end

  it 'guards earned membership extensions on both sides of the old deadline without adding credit' do
    apply
    earned = build(:earned_membership_no_requirements, member: member)
    allow(earned).to receive(:get_shortest_term_end_time).and_return(4.months.from_now.to_i * 1000)
    member.set(expirationTime: 239.hours.ago.to_i * 1000)
    earned.send(:renew_member)
    expect(described_class.read(member.id)[:continuousPaidMembershipMonths]).to eq(12)
    member.set(expirationTime: 241.hours.ago.to_i * 1000)
    earned.send(:renew_member)
    expect(described_class.read(member.id)[:continuousPaidMembershipMonths]).to eq(0)
  end

  it 'rolls back the revoked status and reset together if an in-transaction callback fails' do
    apply
    member.reload
    allow(member).to receive(:update_card).and_raise('card propagation failed')
    expect { member.update!(status: 'revoked') }.to raise_error('card propagation failed')
    expect(member.reload.status).to eq('activeMember')
    expect(member.continuous_paid_membership_months).to eq(12)
    expect(MembershipPaidCreditEntry.where(action: 'reset').count).to eq(0)
  end

  it 'joins an existing card transaction and rolls membership expiration/reset back with it' do
    apply
    member.set(expirationTime: 241.hours.ago.to_i * 1000)
    old_expiry = member.expirationTime
    expect do
      CardManagement.transaction do
        member.update!(renew: 1)
        raise 'outer card operation failed'
      end
    end.to raise_error('outer card operation failed')
    expect(member.reload.expirationTime).to eq(old_expiry)
    expect(member.continuous_paid_membership_months).to eq(12)
    expect(MembershipPaidCreditEntry.where(action: 'reset').count).to eq(0)
  end

  it 'keeps legacy history estimated through unrelated saves while new accounts start complete', requires_transactions: false do
    expect(described_class.read(member.id)[:estimated]).to be(false)
    Member.collection.find(_id: member.id).update_one('$unset' => { continuous_paid_membership_estimated: '' })
    member.reload.update!(firstname: 'Legacy account')
    expect(described_class.read(member.id)[:estimated]).to be(true)
  end
end
