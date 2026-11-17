require 'rails_helper'

RSpec.describe MembershipPaidBackfill, requires_transactions: true do
  before(:all) { MembershipPaidBackfillReport.create_indexes }
  let(:member) { create(:member, expirationTime: 1.month.from_now.to_i * 1000) }

  def history_invoice(person = member, months: 3, at: 1.month.ago, **attributes)
    create(:invoice, member: person, resource_id: person.id.to_s, resource_class: 'member',
      amount: 300, quantity: months, plan_id: nil, settled_at: at, **attributes)
  end

  def legacy_payment(person = member, **attributes)
    Payment.collection.insert_one({ member_id: person.id, product: '6mo-Sub', amount: 1,
      currency: 'USD', status: 'Completed', txn_type: 'subscr_payment', payment_date: 2.months.ago,
      txn_id: SecureRandom.hex(8) }.merge(attributes))
  end

  it 'rejects a nonpositive batch limit before creating a checkpoint', requires_transactions: false do
    expect { described_class.run!(limit: 0) }.to raise_error(ArgumentError, /positive/)
    expect(MembershipPaidBackfillRun.count).to eq(0)
  end

  it 'defaults to dry run, reports source evidence, and never instantiates legacy Payment', requires_transactions: false do
    legacy_payment
    expect(Payment).not_to receive(:new)
    result = described_class.run!
    expect(result[:mode]).to eq('dry_run')
    expect(member.reload.continuous_paid_membership_months).to eq(0)
    report = MembershipPaidBackfillReport.where(member_id: member.id).first
    expect(report.months).to eq(6)
    expect(report.estimated).to be(true)
    expect(MembershipPaidCreditEntry.count).to eq(0)
  end

  it 'deduplicates invoices and raw payments by provider identity and ignores non-membership products' do
    history_invoice(transaction_id: 'same-source')
    legacy_payment(txn_id: 'same-source')
    legacy_payment(product: 'Custom Donation')
    legacy_payment(product: 'Locker Rental')
    described_class.run!(mode: 'apply')
    expect(member.reload.continuous_paid_membership_months).to eq(3)
    expect(MembershipPaidCreditEntry.where(action: 'application').count).to eq(1)
  end

  it 'bridges missing history for active members without inventing payments' do
    history_invoice(months: 1, at: 1.year.ago)
    history_invoice(months: 1, at: 10.days.ago)
    described_class.run!(mode: 'apply')
    expect(member.reload.continuous_paid_membership_months).to eq(2)
    expect(member.continuous_paid_membership_estimated).to be(true)
    expect(MembershipPaidCreditEntry.where(action: 'application').count).to eq(2)
  end

  it 'honors a proven historical lapse even for a currently active member' do
    history_invoice(months: 3, at: 1.year.ago)
    at = 1.month.ago
    AuditLog.collection.insert_one(subject_id: member.id, resource_type: 'Member', resource_id: member.id,
      created_at: at, event_type: 'member_updated', field_changes: {
        'expirationTime' => [1.year.ago.to_i * 1000, 1.month.from_now.to_i * 1000] })
    history_invoice(months: 1, at: at + 1.second)
    described_class.run!(mode: 'apply')
    expect(member.reload.continuous_paid_membership_months).to eq(1)
  end

  it 'seeds source-linked credits so future refunds deduct the historical contribution exactly' do
    invoice = history_invoice
    described_class.run!(mode: 'apply')
    MembershipPaidCredit.refund!(invoice_id: invoice.id, refund_id: 'after-backfill', amount: 100)
    expect(member.reload.continuous_paid_membership_balance).to eq(2)
  end

  it 'resumes with a stable cutoff and never duplicates completed credits' do
    history_invoice
    other = create(:member)
    history_invoice(other)
    first = described_class.run!(mode: 'apply', limit: 1)
    second = described_class.run!(mode: 'apply', run_id: first[:run_id])
    described_class.run!(mode: 'apply', run_id: first[:run_id])
    expect(first[:cutoff]).to eq(second[:cutoff])
    expect(MembershipPaidCreditEntry.where(action: 'application').count).to eq(2)
    expect([member.reload.continuous_paid_membership_months, other.reload.continuous_paid_membership_months]).to eq([3, 3])
  end

  it 'can apply a reviewed dry run using the same cutoff and skips admin corrections' do
    history_invoice
    first = described_class.run!
    described_class.run!(mode: 'apply', run_id: first[:run_id])
    expect(member.reload.continuous_paid_membership_months).to eq(3)
    corrected = create(:member)
    actor = create(:member, :admin)
    MembershipPaidCredit.increase!(member_id: corrected.id, months: 9, expected_revision: 0, reason: 'Verified', actor: actor)
    result = described_class.run!(mode: 'apply')
    expect(corrected.reload.continuous_paid_membership_months).to eq(9)
    expect(result[:counts]['skipped']).to be >= 1
  end

  it 'leaves revoked and deadline-expired accounts at zero and excludes ghost accounts' do
    history_invoice(create(:member, :revoked))
    expired = create(:member, expirationTime: 240.hours.ago.to_i * 1000)
    history_invoice(expired)
    ghost = create(:member, merged_at: Time.current)
    result = described_class.run!(mode: 'apply')
    expect(expired.reload.continuous_paid_membership_months).to eq(0)
    expect(MembershipPaidBackfillReport.where(run_id: result[:run_id], member_id: ghost.id)).not_to exist
  end

  it 'replays live paid applications made after the captured rollout cutoff' do
    history_invoice(months: 3)
    run = MembershipPaidBackfillRun.create!(cutoff: Time.current, mode: 'apply')
    create(:card, member: member)
    live = create(:invoice, member: member, resource_id: member.id.to_s, resource_class: 'member', amount: 100, quantity: 1, plan_id: nil)
    live.settle_invoice
    described_class.run!(mode: 'apply', run_id: run.id)
    expect(member.reload.continuous_paid_membership_months).to eq(4)
    expect(MembershipPaidCreditEntry.where(action: 'application').count).to eq(2)
  end

  it 'can deduct a confirmed refund from a seeded legacy source without an invoice' do
    legacy_payment(txn_id: 'legacy-refund-source')
    described_class.run!(mode: 'apply')
    2.times do
      MembershipPaidCredit.refund_source!(source_key: 'paypal:legacy-refund-source', refund_id: 'verified-refund', amount: '0.5')
    end
    expect(member.reload.continuous_paid_membership_months).to eq(3)
    expect(MembershipPaidCreditEntry.where(action: 'refund').count).to eq(1)
  end

  it 'reports a real concurrent payment conflict and resumes without overwriting the live credit' do
    history_invoice(months: 3)
    create(:card, member: member)
    live = create(:invoice, member: member, resource_id: member.id.to_s, resource_class: 'member', amount: 100, quantity: 1, plan_id: nil)
    injected = false
    allow(described_class).to receive(:process_member).and_wrap_original do |original, *args, **kwargs|
      unless injected
        injected = true
        Thread.new { live.settle_invoice }.value
      end
      original.call(*args, **kwargs)
    end
    first = described_class.run!(mode: 'apply')
    expect(first[:counts]['conflicted']).to eq(1)
    expect(member.reload.continuous_paid_membership_months).to eq(1)
    described_class.run!(mode: 'apply', run_id: first[:run_id])
    expect(member.reload.continuous_paid_membership_months).to eq(4)
  end

  it 'does not attribute an old household payment to a secondary who only belongs to today\'s roster' do
    history_invoice(member, plan_id: 'household-membership-one-month-recurring')
    member.update!(groupName: member.id.to_s)
    group = Group.create!(groupName: member.id.to_s, groupRep: member.fullname, expiry: member.expirationTime)
    secondary = create(:member)
    group.add_subordinate(secondary)
    described_class.run!(mode: 'apply')
    expect(member.reload.continuous_paid_membership_months).to eq(3)
    expect(secondary.reload.continuous_paid_membership_months).to eq(0)
  end

  %w[household member].each do |resource_class|
    it "uses historical evidence for a former secondary with a #{resource_class} invoice" do
      group = create(:group, member: member)
      secondary = create(:member)
      at = 1.month.ago
      AuditLog.collection.insert_one(subject_id: secondary.id, created_at: at - 1.day,
        field_changes: { 'groupName' => [nil, group.groupName] })
      create(:invoice, member: member, resource_class: resource_class,
        resource_id: resource_class == 'member' ? member.id.to_s : group.id.to_s,
        quantity: 3, amount: 300,
        plan_id: resource_class == 'member' ? 'household-membership-one-month-recurring' : nil, settled_at: at)
      group.destroy! if resource_class == 'member'
      described_class.run!(mode: 'apply')
      expect(secondary.reload.continuous_paid_membership_months).to eq(3)
      expect(MembershipPaidCreditEntry.where(member_id: secondary.id, action: 'application').count).to eq(1)
    end
  end

  it 'honors a recorded historical revocation after missing-history continuity was bridged' do
    history_invoice(months: 3, at: 1.year.ago)
    AuditLog.collection.insert_one(subject_id: member.id, created_at: 2.months.ago, event_type: 'membership_revoked')
    history_invoice(months: 1, at: 1.month.ago)
    described_class.run!(mode: 'apply')
    expect(member.reload.continuous_paid_membership_months).to eq(1)
  end
end
