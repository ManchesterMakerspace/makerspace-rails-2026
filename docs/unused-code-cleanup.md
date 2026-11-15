# Unused Rails code cleanup — 2026-10-29

This record documents each removed block from the runtime-code review of
`makerspace-rails-2026`, using `makerspace-react-2026` to verify API consumers.
CI and test harnesses were excluded from cleanup. Relevant application specs
were retained or adjusted to exercise the surviving behavior.

The baseline is Rails commit `da114c79` and React commit `0b2a7c4`. Line numbers
below refer to that Rails baseline, before deletion; method names are the stable
identifiers. Recover an original block with, for example:

```sh
git show da114c79:app/services/service/google_drive.rb
```

Evidence includes runtime references in `app`, `lib`, and `config`; views,
callbacks, symbol/dynamic dispatch, specs and documented console entry points;
React API consumers; and history. The integration review also searched 146
locally available remote-tracking branch snapshots without fetching. Historical
callers on pre-migration branches are distinguished from current callers. This
is a repository-supported reachability determination, not production tracing or
proof about undocumented external console scripts.

## 1. Obsolete Google Drive invitation chain

Files: [member subscriber](../app/subscribers/member_subscriber.rb),
[Google Drive service](../app/services/service/google_drive.rb), and
[admin members controller](../app/controllers/admin/members_controller.rb).

Commit `56770c88` (2026-08-01) removed the subscriber's creation-time Google
invitation call and changed the admin invitation action to
`Service::MemberProvisioning.provision_google`. The old implementation remained
defined even though its application entry points were gone. Earlier callers on
retained branches precede that migration; no later consumer was found.

| Removed block (original lines) | Exact issue and disposition |
| --- | --- |
| `MemberSubscriber#send_google_invite` (86–95) | No subscription or other runtime code calls it. Removed the obsolete two-folder invitation orchestration and its private error handling. |
| `GoogleDrive#invite_gdrive` (51–62) | Its only remaining runtime caller was the disconnected subscriber method. Removed the legacy direct reader-permission creation path. |
| `GoogleDrive#invite_gdrive_writer` (64–75) | Its only remaining runtime caller was the same disconnected subscriber. Removed the legacy direct writer-permission creation path. |
| Instance `GoogleDrive#load_gdrive` (36–38) | Only the removed instance invitation methods used this delegation. Removed the instance wrapper; the live module/class method remains. |
| Instance `GoogleDrive#report_google_error` (240–242) | Only the removed instance invitation methods used this delegation. Removed the instance wrapper; the live module/class error reporter remains. |
| `MemberSubscriber` GoogleDrive extension (2) | No remaining subscriber operation uses the mixed-in methods. Removed the extension. |
| `MemberSubscriber` SlackConnector extension (3) | All surviving subscriber Slack calls are explicitly qualified with `Service::SlackConnector`; no mixed-in method is needed. Removed the extension. |
| `Admin::MembersController` GoogleDrive inclusion (2) | The controller uses the provisioning service and qualified service methods, so the inclusion contributes no used behavior. Removed it. |

The live [member provisioning service](../app/services/service/member_provisioning.rb)
continues to own eligibility, Google permission changes, tracking, retry, and
reconciliation. Document upload/retrieval, backup upload, Drive-client creation,
and their class-method error handling remain intact. The member specs' negative
expectations now target the live provisioning methods instead of methods that no
longer exist. Environment-variable meanings and member-visible behavior do not
change.

## 2. Disconnected legacy invoice and payment reports

File: [analytics service](../lib/service/analytics.rb). These reporting APIs
originated in `19e5ed95` (2021-03-21). Later aggregation optimizations changed their
implementation without adding a production entry point. Searches found only
internal calls or specs, including across the cached branch snapshots. These
blocks do not implement the current dashboard or scheduled invoice review.

| Removed block (original lines) | Exact issue and disposition |
| --- | --- |
| Top-level `require "csv"` (1) | Only the removed CSV exporters needed this dependency. Removed this file's require; unrelated CSV users retain their own requirements. |
| Direct `csv` dependency in `Gemfile` (8) and matching lockfile entries | The removed exporters were the only application users; no remaining app/task/spec code or installed runtime dependency requires CSV. Removed the direct dependency and its now-unneeded locked specification/checksum without upgrading other gems. |
| `Invoices::RENTAL_CATEGORIES` and `MEMBERSHIP_CATEGORIES` (262–273) | Referenced only by disconnected invoice reports. Removed their hard-coded legacy plan mappings. |
| `Invoices.query_all_settled` (295–297) | Default scope only for the removed reports; no independent runtime caller. Removed. |
| `Invoices.get_rentals`, `get_rental_count`, `get_rental_dollars` (299–309) | No external production caller for the rental category report or its projections. Removed together. |
| `Invoices.get_membership_subscriptions`, `get_membership_subscription_count`, `get_membership_subscription_dollars` (311–324) | No external production caller for the subscription category report or its projections. Removed together. |
| `Invoices.aggregate_categories`, `normalize`, and their private declarations (326–358) | Reachable only through the removed category reports. Removed the unused aggregation/normalization implementation. |
| `Invoices.csv_by_date` (360–366) | No application, task, or documented operator entry point invokes the exporter. Removed. |
| `Invoices.query_to_csv` (368–374) | Only the removed exporter calls it; also duplicated the Payments implementation verbatim. Removed. |
| `Payments::DONATION_CATEGORIES`, `MEMBERSHIP_CATEGORIES`, `RENTAL_CATEGORIES` (378–391) | Only the disconnected Payments analytics module consumes these product mappings. Removed. |
| `Payments.not_categorized` and `query_completed` (393–404) | No external runtime callers; the scope serves only the dead reporting family. Removed. |
| `Payments.get_donations` and `get_donation_count` (406–412) | No production caller. Removed the donation report and count projection. |
| `Payments.get_membership_subscriptions`, `get_membership_subscription_count`, `get_membership_subscription_dollars` (414–424) | No production caller. Removed the membership report and projections. |
| `Payments.get_rentals`, `get_rental_count`, `get_rental_dollars` (426–436) | No production caller. Removed the rental report and projections. |
| `Payments.aggregate_categories`, `category_stage`, `regex_branch`, and their private declarations (438–475) | Internal implementation used only by the removed Payments reports. Removed. |
| `Payments.csv_by_date` (477–483) | No production or documented operator caller. Removed. |
| `Payments.query_to_csv` (485–491) | Called only by the dead exporter and identical to the invoice CSV writer. Removed. |
| `Analytics::Payments` namespace (377–492) | No surviving methods or constants after the preceding removals. Removed the empty module boundary too. |

Preserved `Invoices.summary_counts` and the live `query_created`, `query_earned`,
`query_past_due`, `query_refunds_pending`, and `query_settlement_pending` helpers.
The [invoice review task](../lib/tasks/invoice_review.rake), member review task,
and document-notice task retain their queries. This does not remove the Payment
model, payment processing, billing endpoints, or any persisted data.

## 3. Superseded member analytics wrappers

File: [analytics service](../lib/service/analytics.rb).

| Removed block (original lines) | Exact issue and disposition |
| --- | --- |
| `Members.query_new_members` (51–53) | Dashboard caller replaced by `summary_counts` in `a4ca256a` (2026-09-13); only specs continued calling the separate query. Removed. |
| `Members.query_lost_members` and its method-specific comments (55–69) | Same explicit replacement by `summary_counts`; no current production caller. Recent age alone was not the removal rationale. Removed the old wrapper while preserving its lapse-boundary regression against the live aggregate. |
| `Members.get_membership_per_month` (107–111) | Wraps `active_members_by_month` solely to return an unused legacy array format. No current runtime caller. Removed the adapter, preserving the aggregate and its boundary coverage. |

Updated [analytics specs](../spec/lib/service/analytics_spec.rb) to assert concrete
dashboard results rather than treating unused queries as an oracle. Removed
specs/fixtures dedicated to the deleted reports and CSV exports; retained the
live member, lost-member, monthly-boundary, invoice-counter, and refund coverage.

## 4. Superseded Slack channel cache maintenance

File: [Slack channel cache](../app/services/service/slack_channel_cache.rb).

| Removed block (original lines) | Exact issue and disposition |
| --- | --- |
| `refresh_all!` (81–85) | The last internal caller was replaced by `rebuild!` in `6c956baa` (2026-08-06). The incremental full-cache path has no current caller or documented invocation. Removed. |
| `clear!` (114–119) | `98ef583b` (2026-08-06) replaced clear-before-rebuild with atomic cache promotion. No current caller or documented invocation remains. Removed. |
| `write_status` (229–235) | Called only by the disconnected `refresh_all!`; live promotion writes status atomically with cache replacement. Removed. |

The refresh job and operator task still use `rebuild!`. Request-time lookups,
cache writes, refresh-on-miss, status reads, staging cleanup, and atomic promotion
remain. Undocumented console consumers cannot be established from the repository;
the supported operator path is documented in the
[service inventory](jobs-tasks-services.MD).

## 5. Unrouted checkout mutation action

File: [admin checkout controller](../app/controllers/admin/tool_checkouts_controller.rb).

| Removed block (original lines) | Exact issue and disposition |
| --- | --- |
| `Admin::ToolCheckoutsController#update` (87–104) | No route exposes this action. The action dates to April and received incidental locking updates in September, but current and cached route declarations still omit it. Removed the unreachable revocation branch. |
| `update_params` (154–156) | Used only by that unreachable action. Removed. |
| `:update` in the `find_checkout` callback list (5) | Refers only to the deleted action. Removed that member of the list. |

React revocation uses `DELETE /api/admin/tool_checkouts/:id`; expiration changes
use the dedicated `PATCH .../:id/expiration` endpoint. Both live operations,
their authorization, and their locks remain. Corrected the stale `update` entry
in [checkout documentation](checkout.MD). No reachable API endpoint is removed.

## 6. Unused authorization/lookup helpers

| Removed block (original file and lines) | Exact issue and disposition |
| --- | --- |
| `ApplicationController#can_view_disabled_tools?` (97–99) | July's scope refactor (`2e5a1a76`) replaced its callers. It is an ordinary protected helper, not a Rails hook. Removed. |
| `ApplicationController#checkout_visible_tool_ids` (126–132) | Added in the same July change without a consumer; no current or cached-branch caller. Removed the unused query/composition helper. |
| `CheckoutApprover.tool_ids_for_member` (45–48) | Definition only in current runtime code and cached branches. Live callers use `allowed_tool_ids_for_member`, which combines shop and individual grants. Removed the unused narrower lookup. |

Files: [application controller](../app/controllers/application_controller.rb) and
[checkout approver](../app/models/checkout_approver.rb). Live authorization rules,
framework overrides, permission names, and model callbacks are unchanged.

## 7. Duplicate space-usage route declarations

File: [routes](../config/routes.rb), original lines 311–312.

The explicit `GET /api/admin/space_usage` and
`GET /api/admin/space_usage/date_range` declarations duplicate paths, HTTP
methods, controller actions, and authentication scope already generated by the
preceding `resources :space_usage` block (304–308). Both copies were introduced
together in `09da258a` (2026-06-10). Removed only the later declarations; the
resource block and React URLs remain. No API schema or generated client contract
changes. The removed declarations also generated the unused
`admin_space_usage` and `admin_space_usage_date_range` path/URL helpers; no
application, view, task, spec, or documentation caller uses them.

## 8. Unused private checkout keyword

File: [checkout creation service](../app/services/checkout_creation.rb), original
lines 13–14 and 42–43.

`create_under_checkout_lock` accepted `defer_notifications` but never read it.
Removed the private keyword and its forwarded argument. The public `create!`
keyword remains and still chooses queued versus immediate notifications after
persistence. No caller-visible signature, transaction, or delivery behavior
changes.

## Preserved code and documentation obligations

- The live prerequisite checks in `VolunteerEvent` and `VolunteerTask` remain.
  They contain similar logic but both have callers; consolidating their distinct
  eligibility/visibility behavior is a separate refactor, not dead-code removal.
- Framework/Mongoid hooks, the documented TOTP diagnostic, and the recent
  `tool_groups#decide_volunteer` endpoint remain.
- Updated `jobs-tasks-services.MD` for the removed service paths and corrected
  `checkout.MD`. No collection/index, member-status, or permission semantics
  change. No mailer trigger, recipient, subject, template, or fallback changes.
- The environment-variable inventory is unchanged: the surviving provisioning
  service still uses the Google invite flags and folder IDs; no requirement,
  default, or fallback changed.
- No user/operator flow or live endpoint changes, so no WikiPages, API-spec
  contract, Swagger artifact, or API-client publication change is required.
  React sources remain unchanged and no coordinated deployment is needed.

## Validation

Validation used Windows Ruby 3.4 with the committed Bundler lock, disposable
MongoDB 7.0.14 configured as replica set `codexCleanupRs`, and isolated Redis
8.0.5 instances. CI uses MongoDB 7.0 and Redis 7. Local environment values were
CI dummy fixtures; no valued database, real Slack credentials, production jobs,
or release tasks were used. Test-only empty UI stubs were supplied as documented
in `AGENTS.md`.

- `bundle install` completed. After removing CSV, `bundle lock --local` changed
  only its specification, direct dependency, and checksum; `bundle check` passed.
- `bundle exec ruby scripts/ci/verify-mongo-transactions.rb` verified real commit
  and rollback. `REQUIRE_MONGO_TRANSACTIONS=true` remained enabled for the suites.
- Focused RSpec across analytics, members/provisioning, Drive/document upload,
  Slack cache/job, checkout API/expiration/scoped authorization, approver models,
  and ApplicationController: **266 examples, 0 failures, 2 pending**.
- The two pending examples require `SLACK_PROFILE_STATUS` and
  `SLACK_PROFILE_FULLNAME`. Running them with dummy field IDs and mocked Slack
  clients produced **2 failures**, both reproduced on an untouched archive of
  `da114c79` with a separate disposable database. The examples at
  `spec/controllers/admin/members_controller_spec.rb:389` and `:449` expect
  synchronous profile writes removed in June (`c8c73980`, `f6f7b56b`). They are
  unchanged by this cleanup and remain existing optional-test issues.
- A booted comparison against the baseline route file verified identical unique
  verb/path/default contracts and exactly two fewer declarations. No generic
  admin checkout update route existed before or after.
- Ruby syntax checks passed for all changed Ruby sources/specs and `Gemfile`;
  cleanup-record relative links resolve; `git diff --check` passed.

The required `bundle exec parallel_rspec spec/ -n 4` run passed:
**3,647 examples, 0 failures, 3 pending**, in 23 minutes 59 seconds including
worker startup. It used separate `makerspace_cleanup_full_test` worker databases
and a separate Redis instance. A temporary, ignored Ruby preload set factory
BCrypt hashing to its minimum test cost; tracked test harnesses and CI
configuration are unchanged.

The full-suite pending cases are the two optional Slack profile examples above
and the existing `xit` at `spec/mailers/notification_suppression_spec.rb:79`
(secondary-household admin password-reset notice). **No transaction examples
were skipped.** The explicitly enabled optional Slack rerun still fails as
described above, on both the baseline and cleaned code; the normal full-suite
pass must not be interpreted as coverage of those pending cases.

The disposable database/Redis processes were stopped after validation. No
production data migration, client publication, or coordinated React release is
required.
