# Eventbrite integration

The Rails receiver imports organization-owned Events, Orders, Attendees and Ticket
Classes into MongoDB. React uses these records for optional signup attribution and
staff history. Deploy this feature before publishing its wiki instructions.

## Configuration and receiver

Set `EVENTBRITE_API_KEY` to an Eventbrite **private OAuth token**, not the public
application client ID. Set `EVENTBRITE_ORGANIZATION_IDS` to a comma-separated list
of organizations the token can read. Set `EVENTBRITE_WEBHOOK_PATH` to a private
path ending in at least 32 cryptographically random URL-safe characters. An empty
path disables the receiver. Configured paths require both other settings and
cannot use reserved application prefixes. Restart Rails after changing the path.

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

Runs persist their kind, organization list, filters, progress, counters and errors
in `eventbrite_sync_runs`. Resume retains those original criteria. Expired tokens
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
public, valid concrete occurrences from configured organizations, starting within
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

Resource Managers, Board and Admins can view all configured organizations in the
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
