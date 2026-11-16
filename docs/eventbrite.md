# Eventbrite integration

The Rails receiver imports organization-owned Events, Orders, Attendees and Ticket
Classes into MongoDB. React uses these records for optional signup attribution and
staff history. Deploy this feature before publishing its wiki instructions.

## Configuration and receiver

Set `EVENTBRITE_API_KEY` to an Eventbrite **private OAuth token**, not the public
application client ID. `EVENTBRITE_ORGANIZATION_IDS` is an optional comma-separated
allowlist: blank or unset accepts any organization accessible through the token;
a nonempty list restricts imports, signup choices and staff history to those IDs.
Set `EVENTBRITE_WEBHOOK_PATH` to a private
path ending in at least 32 cryptographically random URL-safe characters (letters,
digits, `_` or `-`). Supply only the path, with a leading `/` and no trailing `/`,
hostname or query string: `/eventbrite/<random-secret>` is the shape, with the
placeholder replaced by a freshly generated secret. Prefixes `/api`, `/assets`,
`/billing`, `/slack`, `/members` and `/rails` are reserved.
An empty path silently disables the receiver. An invalid path also disables it,
logging an `Eventbrite webhook disabled` warning without the configured value;
Rails and scheduled tasks continue booting. Valid paths still require the API
token. Correct the path and restart Rails to enable the listener, then update
the full URL in Eventbrite and send a dashboard test. Restart Rails after any path
change. API/backfill credentials are validated separately even with webhooks disabled.

Register the full HTTPS origin plus this path in Eventbrite. Subscribe to Event
Publish/Unpublish/Create/Update, Order Place/Update/Refund, Attendee Update, and
Ticket Class Create/Update/Delete for every intended organization/event. Confirm
the dashboard's test and controlled real deliveries before releasing publicly.
The integration does not create subscriptions on Eventbrite automatically.

Eventbrite does not document an HMAC signature contract. The private URL and
authenticated fetch of organization-owned resources are the boundary. Only exact
HTTPS `www.eventbriteapi.com` resource URLs are accepted, redirects are not
followed, and provider IDs are opaque strings. The API token is needed for live
webhooks as well as backfills. Never expose it in `/api/config` or React builds.
The optional organization allowlist adds a local restriction; it does not grant
access to organizations the token cannot read. With no allowlist, imported records
from all organizations are eligible for staff history and signup filtering.

The privacy middleware rewrites the private path before Rails request logging;
its internal route additionally requires the middleware marker. Configure the
reverse proxy/load balancer to omit or redact access logs for the receiver path.
Never paste the production receiver URL in Swagger, tickets, screenshots, or
public documentation. `config.endpoint_url` is filtered from parameter logs.

Accepted notifications are persisted before `202`; database failure returns
`503`. Test notifications return `200`, unsupported actions return `204`, invalid
payloads return `400`. Never return `410`, which unsubscribes Eventbrite delivery.
Pointer-only notifications are supported. Each arrival is retained independently:
the webhook configuration ID and URL are not delivery identifiers.

## Records and consistency

Events keep provider status, public/listed visibility, occurrence dates/timezone
and invalidation state. Draft/canceled events are invalid; live, started, ended
and completed events remain valid. Republishing restores validity. Orders retain
buyer details, costs and refund evidence; **any** refund permanently invalidates
an order. Free orders are not classified as refunded from their cost. Attendee
updates and order expansions maintain attendee records. Ticket deletion is
confirmed by a complete parent-event ticket listing after the five-minute provider
consistency window; incomplete listings cannot invalidate unseen records.

Resource upserts use leases and reject older provider `changed` timestamps.
Webhook work records persist leases, deadlines, attempts and failure states.
`EventbriteRecoveryJob.perform_now` runs every minute and directly replays due work,
including abandoned workers. Rate limits defer work without consuming error
attempts. Network/server failures have eight attempts; persistent authorization
or resource errors remain failed. Completed deliveries expire after 30 days;
unresolved failures and domain history do not expire.

Every API call shares a token-scoped Redis lease, 0.5-second inter-call delay,
rolling 2,000/hour and 48,000/day budgets, and a shared 429 cooldown. Retry-After
is honored when supplied; otherwise exponential backoff includes jitter.
Pagination preserves filters and opaque continuation tokens. Redis must be
available; there is no unthrottled fallback.

## Manual tasks

API failures include a sanitized `error_description` in the exception message and
the run's `last_error` (or the webhook delivery's `last_error`). Only that string
field is captured, never the complete provider response. Details are limited to
512 characters on one line. The client redacts configured credentials and the
private receiver path, echoed request values except fixed API vocabulary, URLs,
email addresses, long opaque values, and unknown quoted values. Descriptions naming
sensitive identity/authentication fields are omitted conservatively; malformed or
missing descriptions leave the original status/code-only error intact.

To diagnose a failed run after deploying this change, resume it in the same
environment with `RESUME_RUN_ID=<run ID> bundle exec rake eventbrite:backfill_orders`
and inspect its refreshed `last_error`. Existing stored errors are not rewritten,
and capturing a description does not itself fix a rejected argument. Do not share
credentials, receiver URLs, or full response payloads when reporting failures.

Run tasks with the intended Rails environment and database selected. They write
local collections but never place orders, refund payments, or modify Eventbrite.
They can run while webhooks are enabled and share the same API quota.

```sh
bundle exec rake eventbrite:backfill_events
NAME_EXCLUDE='open house' bundle exec rake eventbrite:backfill_orders
NAME_INCLUDE='welding' NAME_EXCLUDE='advanced' bundle exec rake eventbrite:backfill_events
bundle exec rake eventbrite:backfill_attendees
CHANGED_SINCE='2026-11-01T00:00:00Z' bundle exec rake eventbrite:backfill_attendees
CHANGED_SINCE=last bundle exec rake eventbrite:backfill_attendees
RESUME_RUN_ID='<local run ID>' bundle exec rake eventbrite:backfill_orders
bundle exec rake eventbrite:retry_failed
```

In PowerShell, set `$env:NAME_EXCLUDE = 'open house'` before invoking the same
Rake command and remove it afterwards with `Remove-Item Env:NAME_EXCLUDE`.
Name filters are literal case-insensitive substrings, combined as include AND
not-exclude. They apply only to Events/Orders backfill runs, not later webhooks
or existing records. Each task discovers upstream records independently. Events
include ticket classes; Orders request all statuses and attendee/refund expansions.
When the organization allowlist is blank, each new run discovers organizations
through the paginated `users/me/organizations/` API using the same throttled client.
With an allowlist, new runs use those configured IDs instead.

Runs persist their kind, organization list, filters, progress, counters and errors
in `eventbrite_sync_runs`. Resume retains those original criteria and organization
snapshot without rediscovery. A nonempty current allowlist must still permit every
organization in the resumed run; a blank allowlist permits the saved snapshot.
Expired tokens
restart the relevant listing once per invocation. Replayed pages are idempotent; counters measure
processed work and can include replayed records. Errors exit nonzero. For attendee
increments, `last` uses the previous fully successful run's start minus one second
per organization; incomplete runs never advance that watermark. No previous run
means a full import. `retry_failed` clears terminal delivery failures after the
operator corrects configuration; minute recovery performs the retries. Recovery
runs delivery jobs synchronously so a short-lived cron runner does not abandon
an in-memory queue on exit. Leases permit overlapping runners safely.

## Signup and links

The question stays optional. Existing class/walk-in/web/social/referral answers
remain supported; Other has free text, and decline is explicit. Event choices are
public, valid concrete occurrences from imported organizations permitted by the
optional allowlist (all imported organizations when blank), starting within
two calendar months before today through one month ahead (Eastern calendar dates,
inclusive). Only the **event name** is checked for `Open House`, case-insensitively.
Ticket names do not exclude the event. Signup stores a server-derived name/date
snapshot so historical answers survive renames and aging out of the list.

New provider accounts receive the same optional prompt once during onboarding;
existing accounts are not prompted retroactively. Staff can correct attribution
from the existing member edit form. Choosing another source clears the event
reference, and the existing referral linkage rules still apply.

Attendee email matching uses trim/downcase and non-ghost Members. Signup, staff
creation, provider creation, email changes and restoration mark local reconciliation
work; no API request occurs during signup. Existing refunded history can link.
Orders link through attendees, never just their buyer email. A record already
linked to another member is retained and marked with an email mismatch; automatic
matching never transfers it. The browser is read-only, including mismatch records.

## Staff, release and operations

Member-scoped order history is always restricted to orders containing an attendee
linked to that member. Link filters narrow that history; `linked=unlinked` therefore
returns no orders. The global unlinked filter lists orders with no linked attendees.

Resource Managers, Board and Admins can view imported organizations permitted by
the optional allowlist (all imported organizations when blank) in the
Eventbrite menu and member-profile Eventbrite tab. Ordinary members cannot read
their own imported history. The public signup listing and Member serializers
never include attendee/order data. Staff APIs use zero-based `pageNum`, 50 rows,
and `total-items`, with organization/event/status/link/name/email filters.

Deploy Rails and create indexes with `bundle exec rake data:ensure_unique_indexes`
before enabling subscriptions or importing records. Install the updated minute
recovery schedule, verify controlled dashboard deliveries, then backfill and deploy
the full React build. Review pending delivery age, failed deliveries, run errors,
API cooldowns and link conflicts. Check proxy redaction separately from Rails logs.
The generated API client is a separate release; regenerate Swagger, publish the
client, and upgrade React's dependency before releasing the coordinated change.
The prepared 2.10.0 client is tested as a local package under React's `vendor/`
until npm authentication is available. After publication, replace that file
dependency with registry version 2.10.0 and regenerate the Yarn lockfile.
The [client draft PR](https://github.com/ManchesterMakerspace/makerspace-ts-api-client/pull/3)
contains the additive generator and contracts. The
[wiki draft PR](https://github.com/ManchesterMakerspace/WikiPages/pull/6) updates
signup, staff registration, navigation and troubleshooting and adds a staff guide;
hold it until deployment because merging wiki master publishes immediately.

API behavior references: [webhooks](https://www.eventbrite.com/platform/docs/webhooks),
[orders and all-status filters](https://www.eventbrite.com/platform/docs/orders),
[pagination, attendee and refund fields](https://www.eventbrite.co.uk/platform/new/api),
and [rate limits](https://www.eventbrite.com/platform/docs/rate-limits).

## Slack announcements and upcoming reminders

Public listed events (including Open House) are announced after successful
authenticated hydration. Private, invite-only and password-protected events are
excluded. Publish notifications create one initial announcement per event or
series; series publication represents the earliest upcoming occurrence. Duplicate
notifications and republication edit the saved message. Unpublishing marks
existing announcements and reminder rows unavailable and removes registration links.
This update does not wait for ticket inventory or a series listing to succeed.
Fresh publication webhooks retry for up to five minutes if occurrences have not
appeared yet. Historical occurrences without saved messages do not block publication.
Initial publication is queued after successful detail hydration even if ticket
inventory subsequently fails; unknown counts are labeled unavailable. A canceled
or rescheduled first occurrence is rechecked before selecting the series announcement.

Portal Settings → Slack → **Upcoming Events Channel** overrides `upcoming-events`.
Blank restores that default. Existing messages keep their actual Slack channel ID
and timestamp, including development redirection through SLACK_ENV.

Run `bundle exec rake eventbrite:announce_upcoming` for the next 24 hours, or
`bundle exec rake "eventbrite:announce_upcoming[7]"` for seven rolling 24-hour periods.
Only positive whole numbers are accepted. No automatic reminder schedule is installed.
The task discovers upcoming events using the configured organizations, groups series
dates, and refreshes inventory. There is one reminder per event/series per Eastern
calendar day. Repeating with a wider window expands today's post; narrower windows
do not remove prior dates. Up to 20 dates are displayed with an overflow notice.
Initial announcements and reminders are separate. Unsent reminders expire at midnight
Eastern and past-only messages are suppressed. Counts print to stdout; incomplete
delivery raises an error while durable work remains recoverable.
The date window is checked again after fetching event details, so an event moved
outside the requested window is not added from a stale listing.

Sold/remaining counts use provider inventory, include free admission tickets, exclude
add-ons, respect shared pools/custom event capacity, and never count local orders.
Pending purchases reduce both pool and event capacity; shared pools also respect
smaller ticket-class limits. These rules follow the provider's
[inventory and capacity model](https://www.eventbrite.com/platform/new/api).
Partial refunds therefore do not invalidate all tickets in an order for these totals.
Unknown numeric inventory is labeled unavailable; a known sold count is still shown
when remaining capacity is unknown. Order changes refresh all messages
containing the occurrence and request another inventory refresh after five minutes.
Moving an order between occurrences refreshes both dates. The previous date's
delayed reconciliation is saved before importing the transfer, so retries retain it.
Ticket-class and attendee changes also refresh inventory. Backfills never announce.

Slack work is stored in eventbrite_slack_deliveries. Minute recovery handles due work.
Successful receipts are mirrored into each represented event's slack_receipts.
Rate limits defer; other transient failures retry up to eight attempts.
Duplicate notifications preserve existing retry deadlines. Publication selection
and sending share a lease so a concurrent webhook cannot retarget an in-flight post.
Terminal errors retain last_error and failed_at. An interrupted/ambiguous initial
send is not blindly reposted. Operators must inspect Slack before resetting it: attach the
verified ts/channel to the delivery if it exists, or clear sending_at only after
confirming no message was posted. Then clear failed_at, reset attempts to zero and
set due_at to Time.current through the Rails console. Deleted/inaccessible messages
are not automatically replaced. Never edit a receipt across production/test modes.

Deploy Rails and run data:ensure_unique_indexes before enabling publication.
Refresh existing metadata with the silent events backfill, then deploy the complete
React build. Keep wiki instructions on the existing draft until deployment.
