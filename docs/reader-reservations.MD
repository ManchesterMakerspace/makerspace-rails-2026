# Reader reservation attendance and release

This feature requires the companion reservation-enabled ESP32 firmware and ts-data-api.
Reservation support is advisory and does not restrict reader access or switch off tools.

## Lifecycle

Approved bookings accept attendance from an authenticated tool session from one hour
before start through exactly fifteen minutes after start, before their exclusive end.
A current competing booking prevents association. Member IDs, tool IDs and session
times come from immutable checkins/checkend records, not names or MQTT display payloads.
Already-running sessions can claim when eligible. One equipped tool claims the whole
multi-tool/group/shop booking. Ordinary owner logoff cancels the remaining whole booking
with `decision_note=released_on_logoff`; kicks and automatic stops do not.

`abandoned` is a terminal, nonblocking status distinct from cancellation. It retains
all fee and invoice records. Calendar events are removed and Slack reminders/canvases
are synchronized using the existing jobs. No refund, penalty or extra message is sent.
The portal includes abandoned records in history immediately and explains the no-show.

When monitoring begins, freeze enabled `nfc_readers` with `reservationEnabled=true`
for the booking's physical tools (all tools for whole-shop bookings). Unequipped tools
are intentionally excluded. At least one participant is required. Abandonment requires
every participant to synchronize complete, certain attendance through the inclusive
arrival deadline. Offline/reassigned/disabled readers cannot be silently removed from
that proof. A permanently missing participant requires ordinary manager cancellation.
Do not retroactively initialize monitoring after the no-show deadline.

The frozen coverage revision must still match the reader configuration. Disabling
and re-enabling, or moving away and back, cannot resurrect old checkpoints. Direct
operator edits must increment `reservationCoverageRevision` as the gateway does.
Before abandoning, Rails also reconciles uploaded checkins/checkend: an offline
reader may have observed the owner before learning about the booking. Unknown
reboot ending times defer uncertain carried-session evidence.

## Service contract

`POST /api/internal/reader_reservations/sync` is a private, server-to-server endpoint.
Use `Authorization: Bearer <READER_RESERVATION_SERVICE_SECRET>` (at least 32 characters).
It accepts no browser identity or CSRF exemption for any other route. Restrict ingress
to ts-data-api. The API authenticates the reader certificate and supplies `deviceId`;
the device cannot select another identity.

JSON uses camelCase, with a 16 KiB body and at most 16 `operations`. Each operation has
`kind`, `reservationId`, and nonnegative integer `revision`. Kinds:

- `monitor`: initialize participants before the inclusive no-show deadline.
- `claim`: `checkinId`, `observedAt` (trusted UTC milliseconds).
- `release`: `checkendId`, referencing a voluntary logoff after recorded arrival.
- `checkpoint`: `coveredFrom`, `through` (UTC milliseconds), and `uncertain`.

Responses have `results` and `serverTime`. Each result identifies the reservation and
has `outcome` (`accepted`, `stale`, `gone`, or `blocked`); existing records include
`status` and `revision`. Monitoring/checkpoint responses also include `monitored`
and nullable `arrivedAt`, allowing readers to retire resolved expired records.
HTTP 401 means service authentication failed, 422 invalid
input/scope, 409 missing session evidence/conflicting replay/concurrent state, and 5xx
means retryable service failure. Requests must be retried after session-event upload.

`ReaderReservationService` uses the shared reservation shop lock and an atomic
revision/state-version comparison. Embedded receipts deduplicate claims/releases and
reject altered duplicate bodies; at most 256 per booking. A durable `reader_sync_pending`
marker lets retries recover external-job enqueue failures. Side-effect jobs remain
idempotent. Start/resource/member edits invalidate attendance/coverage; end-only edits
retain attendance and increment the revision. Terminal status changes increment it too.

## Deployment

Deploy Rails/Swagger first; set the shared service secret on Rails and ts-data-api.
Set `READER_RAILS_URL` on ts-data-api to the private Rails origin. Deploy the API and
reader indexes, allow reservation-refresh MQTT subscriptions, then deploy the portal
and firmware. Register all participating readers before monitoring live bookings.
Existing reservations default to no recorded attendance/revision zero; no backfill or
historical abandonment task runs. Fees and existing public permissions are unchanged.

The member/operator wiki draft is held in `docs/wiki-reader-reservations.patch` until
this coordinated release is deployed. Hardware acceptance remains a firmware bench task.
