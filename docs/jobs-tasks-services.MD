# Production jobs, tasks, and services

## Shop outage announcements

`ShopAvailabilityService` lets admins, board members, and assigned resource managers
mark a shop out of service with a required reason, or restore it. The shared
reservation service blocks new shop and tool bookings during an outage.
`ShopOutageSlackJob` posts the shop name and reason to its configured Slack channel
on the default queue, retrying failures up to five attempts. It stores Slack's
message timestamp in the shop's `ts_oos` field. Each outage has an `outage_id` used
as Slack's stable client message ID; completed deliveries and superseded outages
are skipped. A new outage clears the prior receipt; restoration retains it.
The job also sends each assigned resource manager with a linked Slack account a
direct message containing the actor's name, shop name, and outage note, even when
the shop has no channel. Member IDs and actor name are captured when the flag
is set; suspended/revoked members are excluded. Before each DM, delivery rechecks
the member's current assignment, notification suppression and active Slack link.
It skips outage DMs after restoration or a newer outage. Legacy raw-Slack-ID
recipient lists are not used to send private outage messages. Per-member receipts
prevent completed DMs from being resent on retry.
The same admin/board/assigned-RM authorization applies to restoring service.
Restoration never clears tool flags. It queues a reply to the original `ts_oos`
in the original channel with `reply_broadcast: true`, recording `ts_in_service`.
If restoration precedes root delivery, the delivery job sends the root first,
then the recovery reply. Failed destinations retry independently of successful
deliveries, up to the job's retry limit.
Setting or clearing a shop outage also queues `ReservationSlackCanvasSyncJob`
for today and tomorrow. Both reservation canvases show a prominent shop-outage
banner above the agenda while the flag is set; restoration removes the banner
without removing bookings or tool flags. Scheduled rebuilds include unavailable
shops even when they have no reservations or existing canvases.

Unscoped repair-ticket creation and note events capture an explicit staff-channel
notification intent. `FixTicketDelivery` sends those events to the configured
`slack_channel_rm`, falling back to the Admin Channel when RM Channel is blank.
This is independent of the optional central ticket feed and uses the normal
delivery receipts/retry handling. Scoped tickets retain their RM/approver routing.

<!-- markdownlint-disable MD013 -->

This is the production operator's inventory of recurring background work. It
covers every job returned by `GET /api/admin/system_configs` or accepted by
`POST /api/admin/system_configs/run_job`, the recurring work configured in
`config/schedule.rb`, and other Rake tasks whose source says they are intended
to recur in production.

Run commands from the application root with the production environment and
production credentials available. Examples below use:

```sh
RAILS_ENV=production bundle exec rake TASK_NAME
```

`data:ensure_checkout_indexes` is a manual deployment task, not recurring work.
It creates only the nonunique checkout performance indexes on
`members(status, expirationTime)`, `tool_checkouts(member_id, revoked_at, tool_id)`,
`checkout_approvers(member_id)`,
`tool_checkout_requests(member_id, status, request_date, _id)`,
`tool_checkout_requests(tool_id, status, request_date, _id)`, and
`tools(shop_id, name, _id, disabled, open)` (case-insensitive collation),
using their model declarations. It can be
rerun and never drops indexes or modifies documents. Unrelated legacy identity
index conflicts do not block it; conflicts on one of its targets are
reported as errors for operator review.

`data:ensure_unique_indexes` runs in the release phase for both buildpack and
container deployments. In addition to the core identity constraints, it installs
the partial unique indexes that permit only one open checkout-approver request
per member/tool and only one volunteer credit per tool checkout. Deployments stop
for operator review when existing duplicate data prevents either constraint from
being created.

The Tool index keeps the equality-scoped shop and case-insensitive name ordering
before the availability inequalities. A test-database `executionStats` comparison
with 6,000 synthetic tools across ten shops returned the same 343 tools with both
indexes and no blocking sort. Adding `open` reduced fetched documents from 514
to 343; both plans examined 601 keys. These fixture results justify the additional
availability field, but are not a production workload benchmark.

`SlackCheckoutRequestJob` handles named `/checkout request` commands and
resolves shops from either the Slack channel ID or normalized channel name. It uses
an exact, case-insensitive tool-name match so similarly named tools cannot be
selected ambiguously, then applies the same checkout-request eligibility service
as the Member Portal and Slack
modal, and rechecks tool/shop availability, membership, prerequisites, existing
checkouts, and open requests immediately before creating a request. Creation is
serialized per member and tool so concurrent Slack deliveries cannot announce
duplicate open requests.
`SlackCheckoutJob` handles approver-driven `/checkout MEMBER TOOL` commands and
resolves the shop from the channel ID or normalized name. It delegates to
`CheckoutCreation`, the same operation as the portal and modal. Authority,
member eligibility, availability, prerequisites, duplicates and selected-request
state are rechecked under the shared per-member/tool lock. `ToolCheckout` closes
the selected request in its callback and retains users-channel invitations;
notifications and audit logging are best effort after creation.

`SlackCheckoutActiveJob` serves `/checkout active [all]` and its `/checkout list
[all]` alias. In a configured shop channel, the command without `all` lists
that shop and omits the redundant shop-name line. With `all`, or when Slack's
channel cannot be resolved to a shop, it lists checkouts across enabled shops
and includes each shop name.
It uses `CheckoutInteractionQuery.listed_active_checkouts` and `CheckoutDisplay`,
the same availability, alphabetical sorting, bulk association loading and detail
content policy as the modal. Disabled resources and revoked checkouts are
excluded. Long messages direct the user to the portal instead of exceeding Slack
limits. Its result is delivered by `SlackCheckoutOutcomeJob`.

`CheckoutNotificationJob` runs on the `slack` queue for modal mutations. It takes
an action (`request`, `approval`, `cancellation`, `approver_volunteer`, or
`approver_volunteer_decision`) and persisted record ID. Approver-volunteer
actions deliver shop-reviewer DMs and requester decision DMs after Slack has
acknowledged the interaction.
The modal saves the mutation under the existing lock, closes the selected request
for approvals, and enqueues side effects before clearing. Request confirmation DMs
(including the tool requestor annotation or shop fallback), request announcements,
cancellation announcement updates, users-channel invitations, checkout DMs,
success announcements and creation audit logging do not call Slack in the
interaction acknowledgement path. Legacy request-modal submissions also defer
their announcements. Portal and textual-command creation retain their existing
notification behavior through the shared services.

Approval delivery invites the member before building its success announcement,
preserving the manual-invitation fallback text. Each approval side effect is
best effort so one failure does not prevent subsequent notifications or audit.
Deleted records and request announcements whose requests are no longer open are
ignored. After a request announcement returns its Slack timestamp, the sender
atomically records its timestamp only if none exists, then reloads the request.
Approval sends use the same first-timestamp-wins operation. If approval or
cancellation completed during the send, the retained message is updated to the
final status. A sender whose timestamp lost the race deletes its redundant post
after updating the retained message, so a late request cannot overwrite an
existing success timestamp or leave a second success announcement behind.
Slack update/delete failures remain best-effort reported notification failures. Slack calls remain outside the
member/tool mutation lock and the interaction acknowledgement path.
Enqueue errors or aborted enqueues are reported without reversing the
saved mutation. This job is separate from final ephemeral/DM outcome delivery;
a working `slack` queue consumer is required for both.

`SlackCheckoutOutcomeJob` runs on the `slack` queue. Checkout modal submissions
queue it after saving request creation, note editing, cancellation or approval,
and before acknowledging success with `response_action: clear`. Legacy
checkout, request and active-list jobs also delegate final delivery to it. It
first posts `replace_original: true`, `response_type: "ephemeral"`, and final
text to the original slash-command response URL. Open/read/write timeouts are
0.5/1/0.5 seconds. Non-2xx responses, invalid URLs and exceptions trigger a
separate replacement-failure report, followed by a DM to the submitting Slack
user. DM failures are reported separately and never escape back into persistence.
Enqueue failures do not undo saved records or become validation errors.

Outcome URLs are encrypted before job enqueueing using the application key
generator. Argument logging is disabled for all four checkout jobs. Reports
contain fixed messages and error class/status only, never raw exceptions, URLs
or outcome bodies. HTTP logging filters response_url and Slack's JSON payload.
No response-URL HTTP request occurs in the interactions controller.

`ToolCheckoutSlackCanvasSyncJob` incrementally updates an extant shop checkout
canvas when one member's checkout is added or revoked. It locates the affected
Canvas section with `canvases.sections.lookup`, applies the member and last-updated
timestamp changes with `canvases.edit`, and falls back to rebuilding the complete
canvas if an incremental lookup or edit fails. Ambiguous member-section matches
also trigger a rebuild rather than deleting a checkout from the wrong tool, and
incremental additions omit inactive or expired members just as full rebuilds do.
Calls that do not identify one
checkout continue to perform a complete canvas rebuild.
Failure to enqueue an added checkout's canvas update is reported without changing
the saved checkout or its closed request into a failed approval.

After a checkout's `revoked_at` value is first persisted, its model callback
synchronously removes the member's tool-specific checkout-approver access,
revokes open volunteer requests, and reverses any checkout-approver credit before
returning. If cleanup fails, including from contention on the member's approver
record, the revoked checkout retains the durable `revocation_cleanup_pending`
marker that was written in the same database update as `revoked_at`. A subsequent
update retries every idempotent cleanup step and clears the marker only after they
all succeed; the checkout remains revoked throughout so a partial failure cannot
restore tool authority. Credit reversals use an ID derived from the original
credit, preventing a retry after a partial failure from inserting a second
negative credit. A successful resumed cleanup also enqueues the checkout-canvas
removal that the failed callback did not reach. The hourly
`MemberProvisioningReconciliationJob` automatically sweeps pending revocations;
failures are reported and isolated per checkout so later pending records are
still attempted and failed records remain marked for the next sweep.

Changing a tool's out-of-service (`disabled`) state enqueues
`ReservationSlackCanvasSyncJob` for today and/or tomorrow when an active
individual-tool reservation overlaps those dates. This keeps operational
reservation canvases synchronized with tool outages and restorations.

The admin endpoint **enqueues** an Active Job and returns before it completes.
Its `key` parameter is the value in the **Admin key** column below. The
application must have a working Active Job queue consumer for those requests.
The direct Rake commands run synchronously in the invoking process.

Document uploads run asynchronously as `DocumentUploadJob` on the `slack`
queue. Its Active Job lifecycle log suppresses arguments because the first
argument contains the complete base64-encoded signature. A separate safe log
entry identifies the resource, member, and document type. If post-upload Drive
verification fails, the retry log includes the member, resource, expected
filename, and destination folder ID that were used for the unsuccessful
lookup. Before uploading, the job checks for the expected file in the
destination folder. If it is already present (for example, when a successful
upload is retried after delayed Drive search indexing), the job does not upload
a duplicate; it reads that archived file back from Drive for the
signed-document email instead of re-rendering it, so the attachment always
matches the exact bytes on file. This retry check -- and the read-back
download -- both use the Active Job ID stored in the Drive file's application
properties, rather than filename alone, so a contract signed earlier on the
same date cannot be mistaken for the current signing attempt.

Slack reservation submissions and modal closures enqueue
`SlackReservationOutcomeJob` on the `slack` queue before acknowledging the
interaction. The job first replaces the original slash-command response with
an ephemeral outcome, using short HTTP connection/read/write timeouts, and
falls back to a direct message to the submitting Slack user. Its arguments are
suppressed from Active Job lifecycle logs because the response URL is a private,
short-lived Slack credential. Delivery failure never rolls back a reservation.

## Admin-triggerable recurring jobs

`SystemConfig::JOB_KEYS` is the source for the list shown by the admin API. A
job wrapper records `job_status_<admin key>` with a completion time and
`success` or `failure`; direct task behavior differs where noted.

| Admin key | Task displayed by API | Manual command | Purpose and effect |
| --- | --- | --- | --- |
| `slack_sync` | `slack:sync_users` | `RAILS_ENV=production bundle exec rake slack:sync_users` | Reads the Slack workspace user list and creates or updates local `SlackUser` identities by matching email addresses to members. It reports created, updated, and unmatched counts to the logs channel. When `slack_sync_enabled` is true, both the task and job wrapper record status. When it is false, the direct task skips and leaves the previous admin-visible status untouched; the job wrapper records the skipped invocation as a success. |
| `slack_profile_sync` | `slack:sync_profiles` | **No Rake task currently exists.** Use `RAILS_ENV=production bundle exec rails runner 'SlackProfileSyncJob.perform_now'`. | Performs an expiration-only incremental sync. It selects members whose `expirationTime` is after the saved `slack_profile_sync_last_run_at` checkpoint and at or before the run time, randomizes that materialized list to distribute calls across members, then attempts to write `Expired` to their Slack custom-profile field. A Slack 429 response pauses the affected update for its `Retry-After` duration and is retried up to five times. On the first run, the lower bound is the Unix epoch. It does **not** reconcile active members or unrelated member-status changes. `slack_profile_sync_enabled` can skip the work. The API-displayed `slack:sync_profiles` task does not exist. See the partial-success warning below before relying on its count or status. |
| `slack_channel_cache` | `slack:refresh_public_channel_cache` | `RAILS_ENV=production bundle exec rake slack:refresh_public_channel_cache` | Rebuilds Redis lookups for active public Slack channels, atomically promotes the staged cache, removes stale live entries, and stores cache metadata. The task calls the job synchronously, so it records status. |
| `member_review` | `member_review` | `RAILS_ENV=production bundle exec rake member_review` | On Sunday in production, compiles membership exceptions (orientation, no purchase, PayPal, missing contracts, and expired members with rentals), notifies affected members where applicable, queues contract emails, and posts a report to Member Relations. On other production days it exits successfully without a report. Only the job wrapper records status. |
| `invoice_review` | `invoice_review` | `RAILS_ENV=production bundle exec rake invoice_review` | On Sunday in production, reports weekly invoice creation/settlement plus past-due, pending-settlement, and pending-refund cases to the treasurer. On other production days it exits successfully without a report. Only the job wrapper records status. |
| `garbage_collect` | `gc` | `RAILS_ENV=production bundle exec rake gc` | Deletes invoicing Redis cache entries older than 30 days and reports success or failure to the logs channel. This does not invoke Ruby's memory garbage collector. Only the job wrapper records status. |
| `db_backup` | `db:backup` | `RAILS_ENV=production bundle exec rake backup` | Runs `mongodump` against `MLAB_URI`, writes a dated archive below `dump/`, uploads it to the configured Google Drive backup folder, removes the temporary MongoDB config file, and reports to the logs channel. The API-displayed and Whenever-scheduled name `db:backup` does not currently exist; the working task is `backup`. Only the job wrapper records status. |
| `card_expiration_check` | `card_on_file_expiration_check` | `RAILS_ENV=production bundle exec rake card_on_file_expiration_check` | Finds active subscribers whose Braintree cards expire in the current Eastern-time month, caches the affected count and card types in Redis until next month, DMs members who have Slack identities, and reports every affected member to Member Relations. Only the job wrapper records status. |
| `reservation_canvas_rebuild` | `reservations:rebuild_slack_canvases` | `RAILS_ENV=production bundle exec rake reservations:rebuild_slack_canvases` | Processes every shop, but rebuilds today's and tomorrow's reservation canvases only when the shop already has either canvas or has a blocking reservation/blackout in that two-day window. Thus it does not provision empty reservation canvases for an inactive shop. It creates a missing daily canvas when the shop qualifies, refreshes agendas and owner access, and stores its ID. Slack does not attach a newly created canvas to the shop channel header; after its first build, a channel manager must manually attach each daily canvas to its respective shop channel with Slack's **+** button. For every shop, including shops skipped by the reservation path, the command calls volunteer-canvas synchronization with `create_if_needed: true` and owner-access synchronization. That call still leaves a shop unchanged when it has no Slack channel (or the channel cannot be resolved), and it creates a missing volunteer canvas only when the shop has at least one claimable top-level task or active event dated today or later. The command also rebuilds every recorded checkout canvas; it warns the interface-log Slack channel and writes an audit entry for a failed checkout canvas before continuing to the next shop. It retries reservation Slack rate limits and fails after collecting reservation/volunteer failures. Only the job wrapper records status. |
| `membership_expiration_notice` | `membership_expiration_notice` | **No Rake task currently exists.** Use `RAILS_ENV=production bundle exec rails runner 'MembershipExpirationNoticeJob.perform_now'`. | Finds active, non-landlord members with no Braintree subscription (`subscription` not true and `subscription_id` blank) and no active Earned Membership whose `expirationTime` falls exactly 3 days out, and emails each a renewal reminder; separately finds the same population whose `expirationTime` fell exactly 1 day ago and emails an expired notice. Each email is sent at most once per expiration -- the sent state is keyed to the exact `expirationTime` value, so it resets automatically once the member renews to a new date. Only the job wrapper records status. |

### Triggering through the admin API

An authenticated admin can enqueue one of the keys above:

```sh
curl -X POST "$APP_URL/api/admin/system_configs/run_job" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  --data '{"key":"member_review"}'
```

The `200` response means the job was enqueued, not that its effects completed.
Inspect the corresponding job status returned by `GET
/api/admin/system_configs` and the application/error-reporting logs.

## Inert Whenever schedule template

`config/schedule.rb` is only a template of intended schedules. The reviewed
production setup does not include the Whenever gem in `Gemfile` or
`Gemfile.lock`, and neither `Procfile` nor `heroku.yml` installs or consumes the
file. Consequently, `whenever --update-crontab` is unavailable in the deployed
bundle and **none of the entries below is activated by this repository**.

Operators must translate each desired entry into an external platform scheduler
or first add and configure a scheduling mechanism. Times below are template
values and would use the chosen scheduler's timezone.

| Template frequency | Template expression | Manual equivalent | Purpose and effect |
| --- | --- | --- | --- |
| Daily at 02:00 | Rake `db:backup` | `RAILS_ENV=production bundle exec rake backup` | Intended to perform the database backup described above. **The configured task name is currently invalid**, because only `backup` is defined. |
| Daily at 07:00 | `SlackProfileSyncJob.perform_later` | `RAILS_ENV=production bundle exec rails runner 'SlackProfileSyncJob.perform_now'` | Performs the Slack profile synchronization described above. The scheduled form enqueues it. |
| Monthly at 03:15 | Rake `slack:refresh_public_channel_cache` | `RAILS_ENV=production bundle exec rake slack:refresh_public_channel_cache` | Refreshes the public-channel Redis cache described above. Whenever's `1.month` interval is translated by Whenever; verify the generated crontab when deploying. |
| Hourly | `MemberProvisioningReconciliationJob.perform_now` | `RAILS_ENV=production bundle exec rails runner 'MemberProvisioningReconciliationJob.perform_now'` | First retries durable pending checkout-revocation cleanup, isolating and reporting failures per checkout, then reconciles initialized members with live Slack state, promotes eligible Slack guests, and periodically revalidates/provisions Google Drive access when Drive invitations are enabled. Provisioning errors are isolated per member and reported without aborting the complete scan. |
| At 08:00 on the first of each month | `CardExpirationCheckJob.perform_later` | `RAILS_ENV=production bundle exec rake card_on_file_expiration_check` | Runs the monthly card-expiration workflow described above. The Rake command performs the service but does not update the admin job status. |
| Daily at 08:00 | `VolunteerEventReminderJob.perform_later` | `RAILS_ENV=production bundle exec rails runner 'VolunteerEventReminderJob.perform_now'` | Finds open volunteer events whose date has passed and attempts to post a reminder for each to the pending-volunteer Slack channel. Individual delivery errors are reported and do not stop later events. The job records success after the scan completes even if one or every delivery failed, so its status does not represent delivery success. This template job is not exposed in the admin jobs list. |
| Daily at 09:00 | `MembershipExpirationNoticeJob.perform_later` | `RAILS_ENV=production bundle exec rails runner 'MembershipExpirationNoticeJob.perform_now'` | Runs the membership-expiration-notice workflow described above. |
| Daily at 09:15 | `FixTicketAssigneeExpirationJob.perform_later` | `RAILS_ENV=production bundle exec rails runner 'FixTicketAssigneeExpirationJob.perform_now'` | Removes expired members from active repair tickets, reopens tickets left without assignees, and releases or rejects linked bounty claims so another eligible member can claim them. Assignment and status changes advance the ticket revision, create delivery events, and are recorded in the audit log. |

## Recurring production Rake tasks not installed by Whenever

These tasks describe recurring production use in their source, but this
repository's Whenever schedule does not invoke them. Configure them in the
deployment scheduler only after choosing appropriate times and considering the
side effects.

| Task | Manual command | Intended cadence, purpose, and effect |
| --- | --- | --- |
| `member_review` | `RAILS_ENV=production bundle exec rake member_review` | Intended weekly. Its built-in production Sunday guard makes other days a no-op. See the admin-job table for notifications and effects. |
| `invoice_review` | `RAILS_ENV=production bundle exec rake invoice_review` | Intended weekly. Its built-in production Sunday guard makes other days a no-op. See the admin-job table for report effects. |
| `volunteering:update_activity` | `RAILS_ENV=production bundle exec rake volunteering:update_activity` | Intended daily. Stores a `MembershipSnapshot` containing IDs of currently active members and reports the count to the logs Slack channel. Re-running on the same date creates another snapshot unless database constraints prevent it. |
| `volunteering:evaluate_requirements` | `RAILS_ENV=production bundle exec rake volunteering:evaluate_requirements` | Intended on the last day of each month and is a no-op on other production dates. Members appearing in more than 21 snapshots for the month have their requirement count updated in the volunteer Google Sheet, with a ten-second pause per member, followed by a Slack completion message. |
| `volunteering:evaluate_eligibility` | `RAILS_ENV=production bundle exec rake volunteering:evaluate_eligibility` | Intended daily. It visits every current and former local member. When a member is absent from the volunteer Google Sheet, it first appends a row containing the member ID, name, start date, completion-count formula, and `N/A` for dates before eligibility; a run can therefore populate the sheet with rows for every missing local member. It then fills only blank volunteer-date cells with `-` when a matching membership snapshot says the member was active or `N/A` otherwise. Existing populated cells, including existing `-` and `N/A` values, are unchanged, so the task will not repair an incorrect populated value. The service sleeps for one second and the Rake loop sleeps for another second per member; adding a missing row introduces another one-second sleep. Allow at least two seconds per existing member, at least three per missing member, and Google API time. It reports completion to the logs channel. |

`RentalVacatingCheckJob` also says it should run nightly, but it has no Rake
task and no entry in `config/schedule.rb`. If production policy requires it,
invoke it with `RAILS_ENV=production bundle exec rails runner
'RentalVacatingCheckJob.perform_now'`. It changes expired `vacating` rentals to
`cancelled`, DMs the member, posts the cancellation notice to the Member
Relations channel, and queues an ended-rental email. It rescues errors per
rental, so a run can finish even when some rentals were not changed.

## Supporting services

Repair ticket delivery jobs accept integer sequence IDs (including their string
form in queued arguments) and legacy ObjectId ticket IDs. Their persisted queue
reservation and recovery behavior is unchanged.
Delivery skips members whose direct notifications are suppressed before Slack
lookup, preserving progress past revoked or suspended recipients.

`ReservationSlackCanvasMemberAccessJob` synchronizes a member's current Slack
canvas access for the supplied shops. Member edits enqueue it when RM shop
access changes. Shop-side RM assignment edits also enqueue it once per added
or removed member, after saving all assignment changes, for that shop only.
Each enqueue failure is logged and does not interrupt the remaining enqueues
or turn the completed shop save into a failed request. Unchanged or omitted
assignments do not enqueue access synchronization.

Recurring jobs should normally be invoked through their job or Rake entry
point, because wrappers provide status tracking and error reporting. The table
below identifies the service that performs each recurring workflow and gives a
synchronous diagnostic invocation where one is useful.

| Service | Manual invocation | Purpose and effect |
| --- | --- | --- |
| `Service::SlackUserSync.sync_all` | `RAILS_ENV=production bundle exec rails runner 'pp Service::SlackUserSync.sync_all'` | Implements bulk Slack identity synchronization. It observes `slack_sync_enabled`; use the Rake task for normal operations and Slack reporting. |
| `Service::SlackProfileSync.sync_all` | `RAILS_ENV=production bundle exec rails runner 'pp Service::SlackProfileSync.sync_all'` | Performs the checkpointed expiration-only Slack profile update described above and observes `slack_profile_sync_enabled`. Eligible members are materialized and shuffled before updates begin, and each profile update honors Slack's `Retry-After` delay for rate-limit responses, retrying up to five times. It is not a full profile-status reconciliation, and its returned count includes selected members whose Slack update failed after retries. This is currently the only direct implementation behind the admin profile-sync job. |
| `Service::SlackChannelCache.rebuild!` | `RAILS_ENV=production bundle exec rails runner 'pp Service::SlackChannelCache.rebuild!'` | Rebuilds and swaps the Redis public-channel cache. Prefer the Rake task, which also records admin-visible status through its job. |
| `Service::MemberProvisioning.reconcile_all!` | `RAILS_ENV=production bundle exec rails runner 'Service::MemberProvisioning.reconcile_all!'` | Implements hourly Slack/Drive reconciliation. It can change remote Slack membership and Google Drive permissions; it is not a read-only audit. |
| `Service::CardExpirationCheck.run!` | `RAILS_ENV=production bundle exec rails runner 'pp Service::CardExpirationCheck.run!'` | Performs the Braintree query, Redis cache update, member DMs, and Member Relations notifications. Prefer the job if admin-visible status is required. |
| `Service::ReservationSlackCanvas.rebuild_all!` | `RAILS_ENV=production bundle exec rails runner 'Service::ReservationSlackCanvas.rebuild_all!'` | Rebuilds the two rolling reservation canvases only for shops with an existing daily canvas or relevant blocking reservation/blackout; it does not create empty canvases for other shops. It calls volunteer-canvas synchronization for every shop, but a shop needs a resolvable Slack channel, and a missing volunteer canvas is created only when a claimable top-level task or current/future active event exists. Newly created reservation canvases require manual attachment to their Slack shop-channel headers. Prefer the Rake task or job for the normal operational path. |
| `Service::GoogleDrive.upload_backup` | Do not call alone; use `RAILS_ENV=production bundle exec rake backup`. | Uploads the archive created by the backup task to Google Drive. Calling it directly requires an existing archive filename and does not create a database dump. |
| `Service::MembershipExpirationNotice.run!` | `RAILS_ENV=production bundle exec rails runner 'pp Service::MembershipExpirationNotice.run!'` | Performs the daily membership-expiration-notice scan and email sends described above. Outside production, it logs each candidate date window and the comma-delimited names (or `nil`) in the expiring-soon and expired lists. Prefer the job if admin-visible status is required. |

## Operational cautions

- Slack API errors from an individual profile update are rescued inside
  `Service::SlackProfileSync.sync_one`. Despite that failure, `sync_all` counts
  the member as synced, advances `slack_profile_sync_last_run_at`, and allows the
  wrapper job to record success. The member is then outside later incremental
  runs even though Slack was not updated. After correcting the Slack error,
  retry that member directly with `RAILS_ENV=production bundle exec rails
  runner 'pp Service::SlackProfileSync.sync_one(Member.find("MEMBER_ID"))'` and
  confirm that it returns the member rather than `nil`. Rate-limit responses
  are first retried up to five times using Slack's requested delay; this warning
  applies if those retries are exhausted. Rewinding the global
  checkpoint is an alternative only when deliberately replaying all expirations
  in that interval and accepting duplicate updates.
- Manual Rake invocations of `member_review`, `invoice_review`, `gc`, `backup`,
  `card_on_file_expiration_check`, and
  `reservations:rebuild_slack_canvases` do not update their admin-visible job
  status. Invoke the corresponding Active Job synchronously when status history
  must reflect the manual run.
- Several workflows send Slack messages, email, or mutate remote Slack, Google,
  Braintree-derived caches, and Google Drive state. A manual run is not a dry
  run, and repeated runs can repeat notifications.
- A reservation canvas rebuild also attempts volunteer-canvas synchronization
  for every shop and can create missing volunteer canvases or change their owner
  access. A missing canvas is created only if the shop has a resolvable Slack
  channel and at least one claimable top-level task or current/future active
  event; shops that fail those prerequisites remain unchanged. Do not treat the
  command as a reservation-only operation. It skips reservation synchronization for
  shops with no existing daily canvas and no relevant blocking reservation or
  blackout, and Slack requires a channel manager to attach each newly created
  daily canvas manually to its shop channel header.
- `VolunteerEventReminderJob` records success when its event scan completes,
  not when its Slack messages are delivered. Each delivery error is rescued and
  reported separately, so check error reporting when delivery confirmation
  matters even if `job_status_volunteer_event_reminder` says `success`.
- The database backup task writes a credentials-bearing config file in `/tmp`
  only for the duration of the run and removes it in `ensure`; protect process
  output and the generated archive as production data.
- Review worker, Redis, MongoDB, Slack, Google, Braintree, and environment
  configuration before enabling scheduler entries. Failures are generally sent
  to the central error reporter and/or Slack logs channel, but per-record rescue
  behavior can allow a job to complete after partial failure.

## Repair ticket delivery

`FixTicketDeliveryJob` delivers each ticket's pending events in revision order under a renewable per-ticket Redis lease (`FixTicketDeliveryLease`). It creates/repairs central Slack roots, posts threaded/broadcast updates, optional shop summaries and recipient DMs. Stable per-event delivery IDs and persisted receipts support retries; failures do not roll back committed tickets. Retry policy: polynomial backoff, eight attempts. A MongoDB reservation (delivery_job_id and delivery_job_until on the ticket) admits only one queued/running/retrying job chain per ticket. Enqueue failure, success, or exhausted retries release it by matching job ID. Every enqueue and running lease heartbeat renews the reservation for 24 hours beyond the current/scheduled time; an abandoned reservation can then be replaced, and stale job IDs stop without spawning retries. Events arriving during delivery are rechecked after release. Reservation writes never advance the ticket update timestamp.

`FixTicketDeliveryRecoveryJob` runs every ten minutes in config/schedule.rb; it re-enqueues tickets with undelivered events, including events whose original queue enqueue failed. External schedulers may run `bundle exec rake fix_tickets:recover_deliveries` every ten minutes instead. `data:ensure_unique_indexes` creates repair ticket, event, and reveal indexes alongside the core indexes during deployment. `fix_tickets:ensure_indexes` remains a compatibility alias for that task. FixTicketService owns transactional mutations/outbox creation; FixTicketPolicy owns scopes/capabilities; FixTicketDelivery owns notification content and routing.

Central repair-ticket delivery allowlists status, confirmation, assignments, and announcement-note changes plus new discussion notes/bounties. Unrelated field updates do not create central replies or roots.

FixTicketService maps MongoDB `TransactionsNotSupported` to an actionable HTTP 503 error; it never retries ticket writes outside a transaction. Local single-node replica-set setup is documented in `fix-tickets.MD`.

Ticket mutations enqueue `VolunteerSlackCanvasSyncJob` for the linked shop after commit when creating a bounty or cancelling an available bounty through ticket closure/withdrawal. Rolled-back mutations do not enqueue canvas updates.

Linked bounty release/rejection defers its claimant Slack notification and `VolunteerSlackCanvasSyncJob` until after assignment and event writes commit; transaction aborts/retries do not publish those effects.

Linked bounty claims also suppress the superclass canvas enqueue inside the transaction. One canvas sync (with the claimed task ID struck) is enqueued only after the claim, assignment, and event writes commit; aborted claims enqueue none.

Checkout canvas catalog synchronization includes out_of_service changes. Visible unavailable tools show an Out of service - do not use warning; Hidden remains independent.

`SlackVolunteerJob` filters personalized bounty listings through `VolunteerTask#eligible_for?` for every role, before the 15-task limit. Linked-ticket reporter and prerequisite restrictions apply; ordinary-task privileged exemptions remain.

Repair-ticket delivery skips missing optional shop destinations, and scopes central reply receipts to the current Slack thread so recovery can republish pending events after root deletion.

### Volunteer task and repair-ticket visibility

Volunteer task Slack listings and claim-error messages apply the viewer's catalog
visibility; shared volunteer canvases omit hidden task prerequisite names. Hidden-shop
canvases use a generic header and rename existing titles on refresh.
Stored prerequisites continue to govern eligibility. Repair-ticket announcements
also run when shop or tool references change, selecting the current tool/shop
channel and retaining per-event delivery receipts to prevent duplicate sends.

Tool availability updates queue `ReservationSlackCanvasSyncJob` for each affected active, unexpired reservation overlapping today or tomorrow in the reservation time zone. Tool restoration also refreshes these dates. Reservation canvases retain bookings and label individually booked out-of-service tools as unavailable.
