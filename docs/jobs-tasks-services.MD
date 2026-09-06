# Production jobs, tasks, and services

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

The admin endpoint **enqueues** an Active Job and returns before it completes.
Its `key` parameter is the value in the **Admin key** column below. The
application must have a working Active Job queue consumer for those requests.
The direct Rake commands run synchronously in the invoking process.

## Admin-triggerable recurring jobs

`SystemConfig::JOB_KEYS` is the source for the list shown by the admin API. A
job wrapper records `job_status_<admin key>` with a completion time and
`success` or `failure`; direct task behavior differs where noted.

| Admin key | Task displayed by API | Manual command | Purpose and effect |
| --- | --- | --- | --- |
| `slack_sync` | `slack:sync_users` | `RAILS_ENV=production bundle exec rake slack:sync_users` | Reads the Slack workspace user list and creates or updates local `SlackUser` identities by matching email addresses to members. It reports created, updated, and unmatched counts to the logs channel. `slack_sync_enabled` can make the service skip the run. Both the task and job wrapper record status. |
| `slack_profile_sync` | `slack:sync_profiles` | **No Rake task currently exists.** Use `RAILS_ENV=production bundle exec rails runner 'SlackProfileSyncJob.perform_now'`. | Performs an expiration-only incremental sync. It selects members whose `expirationTime` is after the saved `slack_profile_sync_last_run_at` checkpoint and at or before the run time, then attempts to write `Expired` to their Slack custom-profile field. On the first run, the lower bound is the Unix epoch. It does **not** reconcile active members or unrelated member-status changes. `slack_profile_sync_enabled` can skip the work. The API-displayed `slack:sync_profiles` task does not exist. See the partial-success warning below before relying on its count or status. |
| `slack_channel_cache` | `slack:refresh_public_channel_cache` | `RAILS_ENV=production bundle exec rake slack:refresh_public_channel_cache` | Rebuilds Redis lookups for active public Slack channels, atomically promotes the staged cache, removes stale live entries, and stores cache metadata. The task calls the job synchronously, so it records status. |
| `member_review` | `member_review` | `RAILS_ENV=production bundle exec rake member_review` | On Sunday in production, compiles membership exceptions (orientation, no purchase, PayPal, missing contracts, and expired members with rentals), notifies affected members where applicable, queues contract emails, and posts a report to Member Relations. On other production days it exits successfully without a report. Only the job wrapper records status. |
| `invoice_review` | `invoice_review` | `RAILS_ENV=production bundle exec rake invoice_review` | On Sunday in production, reports weekly invoice creation/settlement plus past-due, pending-settlement, and pending-refund cases to the treasurer. On other production days it exits successfully without a report. Only the job wrapper records status. |
| `garbage_collect` | `gc` | `RAILS_ENV=production bundle exec rake gc` | Deletes invoicing Redis cache entries older than 30 days and reports success or failure to the logs channel. This does not invoke Ruby's memory garbage collector. Only the job wrapper records status. |
| `db_backup` | `db:backup` | `RAILS_ENV=production bundle exec rake backup` | Runs `mongodump` against `MLAB_URI`, writes a dated archive below `dump/`, uploads it to the configured Google Drive backup folder, removes the temporary MongoDB config file, and reports to the logs channel. The API-displayed and Whenever-scheduled name `db:backup` does not currently exist; the working task is `backup`. Only the job wrapper records status. |
| `card_expiration_check` | `card_on_file_expiration_check` | `RAILS_ENV=production bundle exec rake card_on_file_expiration_check` | Finds active subscribers whose Braintree cards expire in the current Eastern-time month, caches the affected count and card types in Redis until next month, DMs members who have Slack identities, and reports every affected member to Member Relations. Only the job wrapper records status. |
| `reservation_canvas_rebuild` | `reservations:rebuild_slack_canvases` | `RAILS_ENV=production bundle exec rake reservations:rebuild_slack_canvases` | Rebuilds today's and tomorrow's reservation Slack canvases for every shop. It creates missing reservation canvases and refreshes their agendas and owner access when relevant. For **every** shop it also synchronizes the volunteer canvas with `create_if_needed: true` and owner-access synchronization, so the run can create or mutate volunteer canvases. It retries Slack rate limits and fails after collecting per-shop failures. Only the job wrapper records status. |

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
| Hourly | `MemberProvisioningReconciliationJob.perform_now` | `RAILS_ENV=production bundle exec rails runner 'MemberProvisioningReconciliationJob.perform_now'` | Reconciles initialized members with live Slack state, promotes eligible Slack guests, and periodically revalidates/provisions Google Drive access when Drive invitations are enabled. Errors are isolated per member and reported without aborting the complete scan. |
| At 08:00 on the first of each month | `CardExpirationCheckJob.perform_later` | `RAILS_ENV=production bundle exec rake card_on_file_expiration_check` | Runs the monthly card-expiration workflow described above. The Rake command performs the service but does not update the admin job status. |
| Daily at 08:00 | `VolunteerEventReminderJob.perform_later` | `RAILS_ENV=production bundle exec rails runner 'VolunteerEventReminderJob.perform_now'` | Finds open volunteer events whose date has passed and posts a reminder for each to the pending-volunteer Slack channel. Individual notification errors are reported and do not stop later events; the job records aggregate run status. This job is scheduled but is not exposed in the admin jobs list. |

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
| `volunteering:evaluate_eligibility` | `RAILS_ENV=production bundle exec rake volunteering:evaluate_eligibility` | Intended daily. Recalculates every member's volunteer-date eligibility in the volunteer Google Sheet, sleeps one second per member, and reports completion to the logs channel. Expect a long run for a large membership. |

`RentalVacatingCheckJob` also says it should run nightly, but it has no Rake
task and no entry in `config/schedule.rb`. If production policy requires it,
invoke it with `RAILS_ENV=production bundle exec rails runner
'RentalVacatingCheckJob.perform_now'`. It changes expired `vacating` rentals to
`cancelled`, DMs the member, posts the cancellation notice to the Member
Relations channel, and queues an ended-rental email. It rescues errors per
rental, so a run can finish even when some rentals were not changed.

## Supporting services

Recurring jobs should normally be invoked through their job or Rake entry
point, because wrappers provide status tracking and error reporting. The table
below identifies the service that performs each recurring workflow and gives a
synchronous diagnostic invocation where one is useful.

| Service | Manual invocation | Purpose and effect |
| --- | --- | --- |
| `Service::SlackUserSync.sync_all` | `RAILS_ENV=production bundle exec rails runner 'pp Service::SlackUserSync.sync_all'` | Implements bulk Slack identity synchronization. It observes `slack_sync_enabled`; use the Rake task for normal operations and Slack reporting. |
| `Service::SlackProfileSync.sync_all` | `RAILS_ENV=production bundle exec rails runner 'pp Service::SlackProfileSync.sync_all'` | Performs the checkpointed expiration-only Slack profile update described above and observes `slack_profile_sync_enabled`. It is not a full profile-status reconciliation, and its returned count includes selected members whose Slack update failed. This is currently the only direct implementation behind the admin profile-sync job. |
| `Service::SlackChannelCache.rebuild!` | `RAILS_ENV=production bundle exec rails runner 'pp Service::SlackChannelCache.rebuild!'` | Rebuilds and swaps the Redis public-channel cache. Prefer the Rake task, which also records admin-visible status through its job. |
| `Service::MemberProvisioning.reconcile_all!` | `RAILS_ENV=production bundle exec rails runner 'Service::MemberProvisioning.reconcile_all!'` | Implements hourly Slack/Drive reconciliation. It can change remote Slack membership and Google Drive permissions; it is not a read-only audit. |
| `Service::CardExpirationCheck.run!` | `RAILS_ENV=production bundle exec rails runner 'pp Service::CardExpirationCheck.run!'` | Performs the Braintree query, Redis cache update, member DMs, and Member Relations notifications. Prefer the job if admin-visible status is required. |
| `Service::ReservationSlackCanvas.rebuild_all!` | `RAILS_ENV=production bundle exec rails runner 'Service::ReservationSlackCanvas.rebuild_all!'` | Rebuilds all shops' two rolling reservation canvases and synchronizes every shop's volunteer canvas, creating it when absent and refreshing owner access. Prefer the Rake task or job for the normal operational path. |
| `Service::GoogleDrive.upload_backup` | Do not call alone; use `RAILS_ENV=production bundle exec rake backup`. | Uploads the archive created by the backup task to Google Drive. Calling it directly requires an existing archive filename and does not create a database dump. |

## Operational cautions

- Slack API errors from an individual profile update are rescued inside
  `Service::SlackProfileSync.sync_one`. Despite that failure, `sync_all` counts
  the member as synced, advances `slack_profile_sync_last_run_at`, and allows the
  wrapper job to record success. The member is then outside later incremental
  runs even though Slack was not updated. After correcting the Slack error,
  retry that member directly with `RAILS_ENV=production bundle exec rails
  runner 'pp Service::SlackProfileSync.sync_one(Member.find("MEMBER_ID"))'` and
  confirm that it returns the member rather than `nil`. Rewinding the global
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
- A reservation canvas rebuild also synchronizes every volunteer canvas and can
  create missing volunteer canvases or change their owner access. Do not treat
  it as a reservation-only operation.
- The database backup task writes a credentials-bearing config file in `/tmp`
  only for the duration of the run and removes it in `ensure`; protect process
  output and the generated archive as production data.
- Review worker, Redis, MongoDB, Slack, Google, Braintree, and environment
  configuration before enabling scheduler entries. Failures are generally sent
  to the central error reporter and/or Slack logs channel, but per-record rescue
  behavior can allow a job to complete after partial failure.
