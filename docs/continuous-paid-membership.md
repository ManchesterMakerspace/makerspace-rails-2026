# Continuous paid membership months

## Counting and API

`members.continuous_paid_membership_balance` is a nonnegative decimal balance;
`continuous_paid_membership_months` persists its floor. GET reads stored fields
without scanning payment history. It returns effective zero once 240 elapsed
hours have passed since expiration, including the exact boundary and daylight
saving changes. A missing expiration has no calculable timeout; new accounts
start at zero.

Invoice duration application credits the purchased quantity immediately,
including prepaid terms and confirmed cash/check settlement. Payments held until
the first fob count when released. Admin Renew, earned membership, joining a
household, and other unpaid extensions add no months. Every expiration update
checks the previous persisted expiration first; a late extension cannot restore
an old balance. Revocation resets in the status-write transaction. Suspension
alone preserves the balance, subject to the ordinary expiration rule.

A confirmed cash/check receipt held for the first fob is shown as paid in invoice
responses and list filters, and excluded from past-due analytics and processor
invoice matching/cancellation. Its `settled_at` and paid-month credit remain
unset until release. Repeating settlement is rejected before any processor call
with “Payment already received. Membership time is held until the first fob is
issued.” If accounting failed after the receipt was recorded, an Admin may
retry applying that same confirmed receipt without taking another payment.
For recurring cash/check invoices, application and next-cycle creation commit
together. The parent stores the created invoice ID; a held receipt or recovered
application never creates that cycle twice.

Both household invoice forms are supported: an invoice addressed to `Group`,
or a household-plan member invoice. Each member covered at application receives
the quantity. The saved recipient list determines subsequent refunds, regardless
of later household changes. Joining adds no retroactive credit.

GET `/api/members/:id/continuous_paid_membership` permits self, Admin, and Board.
Resource Managers can read their own balance; their role grants no other access.

```json
{"continuousPaidMembershipMonths":12,"revision":7,"estimated":false}
```

PUT `/api/admin/members/:id/continuous_paid_membership` is **Admin only**. It
accepts `continuousPaidMembershipMonths`, `expectedRevision`, and a nonblank
`reason` of at most 2,000 characters. The requested integer must exceed the
current decimal balance. Invalid, equal, or lower values return 422; stale
revisions return 409. Revoked accounts, missing expiration dates, and dates at/
past the deadline require eligibility/expiration restoration first. The balance
becomes the requested whole number. Balance, ledger entry, and
`continuous_paid_membership_months_increased` audit commit together; audit failure
rolls everything back. The audit includes actor, subject, reason, old/new decimal
balance and timestamp. Generic member updates never permit accounting fields.
Normal session, completed TOTP, and CSRF protections apply.

## Refunds and transactions

The ledger retains source/member/action identities, original paid amount and
currency, months, streak, coverage dates, and confirmed refund identities.
Cumulative deduction is `original months * cumulative refunds / original amount`,
capped at the original months. Decimal arithmetic retains fractional months;
a full refund removes the exact remaining contribution. A duplicate refund is a
no-op; a changed amount for the same identity returns 409. Old-streak refunds
remain recorded without reducing the current streak. Refunded held payments add
no negative credit; fully refunded held payments are never released. Refund
requests have no effect.
Confirmed refunds and settlement reversals continue to update the saved credit
entries for soft-deleted recipients. Their accounts stay hidden; one deleted
household recipient does not prevent accounting for the others.

Successful portal refunds, settled provider refund notifications, explicit
provider reconciliation, and confirmed offline refunds use the same service.
Refunds leave expiration unchanged. Settlement declines reverse applied credit
and the existing duration operation once; held declines never subtract duration.
If a declined invoice is charged again, the new transaction ID is a distinct
payment attempt; application, later refunds, and any reversal use only that
attempt's ledger source. The earlier reversed source remains for audit.
If the processor refunded successfully but local accounting failed, reconcile
before issuing another processor refund. Reconciliation/offline recording send
no money and no email.

`MembershipPaidCredit` uses real MongoDB transactions, explicit sessions on raw
driver writes, optimistic revisions, and at most five attempts with bounded
backoff. Generic saves use one attempt and return a refresh/retry conflict.
Cached association queries are cleared before ending sessions.
`MembershipPaidDeferredEffects` defers provider/queue callbacks until commit.
Processor calls stay outside retries. No standalone-database fallback exists.
Lifecycle writes inside an existing card/ticket transaction join its session
and retain that operation's existing commit/retry/notification policy. First-fob
paid release remains after the assignment commits.
Raw writes bypassing lifecycle callbacks are data repairs and must explicitly
use the accounting service.

`MembershipPaidResetJob.perform_now` runs every minute through Whenever,
independent of nondurable queue delivery. Its indexed sweep rechecks expiration,
status, revision and streak conditionally. The GET's effective-zero rule closes
the interval before persistence. The counter grants no access eligibility and
does not affect prices.

## Historical rollout and operator commands

No new environment variables are introduced. Select the intended existing Rails/
MongoDB configuration in the launching shell. Backfill application is a separately
reviewed production operation.

1. Deploy additive models and live accounting; run
   `bundle exec rake membership:ensure_paid_indexes` to create ledger, report,
   and expiration/balance indexes without rewriting member data.
2. Run `bundle exec rake membership:backfill_paid_months`. The default `dry_run`
   writes only checkpoints and review reports. Output includes a run ID, stable
   cutoff, and initialized, estimated, skipped, conflicted and failed counts
   (exclusive statuses). Inspect private `membership_paid_backfill_reports`
   for source evidence and issues; never publish member-specific reports.
3. Resume a bounded dry run with
   `bundle exec rake "membership:backfill_paid_months[dry_run,RUN_ID,100]"`.
   The third argument limits members per invocation.
4. After review, explicitly apply the same cutoff with
   `bundle exec rake "membership:backfill_paid_months[apply,RUN_ID,100]"`.
   Repeat to resume. Failed/conflicted accounts retry; completed baselines and
   admin corrections are preserved. Balance, entries, provenance and successful
   report commit together. Member revisions and source-invoice writes protect
   concurrent activity; later live entries are replayed.
5. Release the generated client and complete React bundle after baseline review/
   application. Publish the held wiki PR only after deployment.

Historical inputs are applied invoice quantities, expiration/status audit
transitions, live entries, and raw `Payment.collection` records. Instantiating
`Payment` is prohibited because initialization mutates members. Duplicate provider
transaction IDs count once. Explicit legacy mappings cover individual/monthly
products and plan IDs, discounted monthly plans, quarterly three-month plans,
six-month plans, and twelve-month plans listed in
`MembershipPaidHistory::LEGACY_DURATION_MONTHS`. Current prices never determine
duration. Rentals, donations, fees, unpaid invoices, and unreleased held payments
are excluded. Unmapped products and unmatched payment audits require review.

Active, unexpired members may bridge gaps with incomplete coverage; only
identifiable paid months are summed. Explicit revocations and before-expiration
evidence of a 240-hour lapse break continuity. Missing coverage, unknown legacy
refund identities/times, incomplete household recipients and inferred gaps are
estimated. Historical household recipients require a saved application roster
or historical membership evidence; today's secondary roster is never used.
Both historical group-addressed invoices and household-plan invoices addressed
to the primary are considered. The latter retain the primary's member ID even
after a group is deleted, so historical secondary membership evidence can match.
Revoked/deadline-expired accounts stay zero. Unresolved legacy provider links
remain flagged for manual refund review.
Live payment entries marked with a revoked streak contributed zero when applied;
historical replay keeps them at zero after restoration, and later refunds of
those entries cannot subtract from a new paid streak.

Record a **confirmed** offline refund with
`bundle exec rake "membership:record_paid_refund[INVOICE_ID,REFUND_ID,AMOUNT,USD]"`.
Use a stable receipt/reference ID and this refund's amount, not the cumulative
amount. For a provider charge, use
`bundle exec rake "membership:reconcile_paid_refunds[INVOICE_ID]"`; read-only
Braintree requests find and record successful refunds idempotently.

For a verified legacy/deleted-invoice source, use
`bundle exec rake "membership:record_paid_source_refund[SOURCE_KEY,REFUND_ID,AMOUNT,USD]"`.
The source must already have seeded application entries. Verify its provider/
receipt match before recording; the service validates currency and deduplicates
the refund. It uses source-entry revisions when no invoice remains.

`scripts/ci/paid-membership-fixtures.rb` creates only fixed `example.com` browser
fixtures, requires test mode and the disposable-database guard, and uses the test
job adapter. It makes no processor calls or reset. It supports the companion
profile-only acceptance suite without Braintree seeding; it is not an operator
production command.

Monitor `[MembershipPaidCredit] transaction_failed` and `reset_count` logs,
positive balances with deadline-expired dates (reset backlog), duplicate source/
refund deliveries, and failed/conflicted/estimated backfill reports. Review
estimates against source evidence before correcting them. Production backfills,
refund recording and reset sweeps are not routine validation commands.
