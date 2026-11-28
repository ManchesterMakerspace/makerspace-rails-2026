# Public Resources

## Reservation announcement interactions and shop settings

`POST /slack/interactions` additionally accepts signed message `block_actions`
with action ID `reservation_open` and a shop ID value. Slack signature and replay
checks remain mandatory; the server resolves the clicking Slack user to an active,
unexpired linked member before opening the existing reservation modal. Invalid
or ineligible attempts receive private modal guidance. No reservation is created
by the button itself. The announcement's response URL is not used for outcome
replacement; later outcomes are delivered by DM.

Authenticated shop JSON adds Boolean `slackAnnounceEmptyReservations`, default
false. Existing `/api/admin/shops` create and `/api/admin/shops/:id` update accept
`slack_announce_empty_reservations` (JSON camel input is transformed normally).
Omitting it during update preserves the saved value. Existing shop-scoped RM,
admin/board authorization, session/TOTP, and CSRF requirements are unchanged.
`GET /api/admin/system_configs` lists `reservation_slack_announcements`, accepted
by the existing `POST /api/admin/system_configs/run_job` endpoint.

The resulting Slack summaries contain reservation titles, member names, resources,
times, and statuses in their configured destination channels, and grant those
destinations read access to the linked shop agenda canvas. They add no anonymous
Rails route or new public reservation representation. See
[daily announcements](reservations.MD#daily-channel-announcements).

## Authenticated paid membership representation

`GET /api/members/:id/continuous_paid_membership` returns only
`continuousPaidMembershipMonths`, `revision` and `estimated` as JSON. It requires
a normal authenticated, TOTP-complete session and permits self, Admin or Board;
it is not public, and Resource Manager alone grants no other-member access.
`PUT /api/admin/members/:id/continuous_paid_membership` requires Admin and CSRF,
accepts desired whole months, expected revision and required reason, and returns
the same representation (422 invalid/ineligible, 409 stale). Neither route exposes
payment history or adds balance fields to generic member representations. See
[contract, counting and rollout](continuous-paid-membership.md).

Authenticated member/admin invoice lists also recognize confirmed cash/check
receipts held until first-fob issuance as paid: `settled=true` includes them,
`settled=false` and `pastDue=true` exclude them. `pastDue=false` includes them;
the serialized receipt has `settled: true`, `pastDue: false` while paid months
remain zero until the duration is released. Existing invoice role scopes apply.

This document is the source-of-truth inventory for public, deep-linkable Rails
resources owned by this repository. Add a row whenever a server-rendered page or
API endpoint is intentionally usable without a member session, and link a feature
document that follows the structure below.

| Route pattern | HTTP method | Intended audience/device | Authentication or token behavior | Supported formats | Required parameters | Optional parameters | Owning controller | Feature document |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `/api/config` | `GET` | Portal browser/PWA/native clients before login | No member session | JSON | None | None | `ClientConfigController#index` | [Runtime configuration](#public-runtime-configuration), [environment variables](environment-vars.MD) |
| `/api/members/sign_in` | `POST` | Portal browser/PWA/native clients | Password authentication or existing session/remember cookie; CSRF protected; TOTP may be required | JSON | `member.email`, `member.password` for credential login; empty body for restoration | `member.rememberMe` (default false, phones only) | `SessionsController#create` | [Authentication](authentication.md) |
| `/api/auth/firebase_login` | `POST` | Portal provider-login clients | Verified Firebase credential; CSRF protected; TOTP may be required | JSON | `id_token` | `rememberMe` (default false, phones only) | `FirebaseAuthController#login` | [Authentication](authentication.md) |
| `/manifest.webmanifest`, `/service-worker.js`, `/offline.html`, `/pwa-icon.png`, `/pwa-icon-192.png`, `/pwa-icon-512.png` | `GET` | Installable member portal | Public static files; manifest references 192×192 and 512×512 PNG icons; offline page contains no member data | Manifest JSON, JS, HTML, PNG | None | None | Static public file server | [NFC/mobile deployment](../../makerspace-react-2026/docs/nfc-mobile.md) |
| `/api/shortcodes/:code` | `GET` | MMS Portal QR scanner and public API consumers | No session; destination retains its authorization | JSON | `code` (path) | None | `ShortcodeResolutionsController#show` | [Shortcode resolution](shortcode-resolution.MD) |
| `/reservations/agenda` | `GET` | Shop displays, kiosks, and direct browser/API consumers | No member session; optionally requires `token` when a reservation token is configured | HTML, JSON | `shop` (query) | `tool`, `token` (query); `.json` extension or JSON `Accept` header | `ReservationAgendasController#index` | [Shop and tool reservations](reservations.MD#public-reservation-agenda) |
| `/api/rental_spots/:id/public` | `GET` | QR/deep-link visitors and Member Portal pre-login landing pages | No member session or token | JSON | `id` (path; MongoDB ID or spot number) | None | `RentalSpotsController#public_show` | [Public rental spots](rental-spots.MD) |
| `/volunteer/bounties` | `GET` | Public displays, integrations, and prospective volunteers | No member session; shared `token` required only when volunteer token gating is enabled | HTML, JSON, XML | None | `shop`, `token` (query); `.json`/`.xml` extension or matching `Accept` header | `Volunteer::BountiesController#index` | [Public volunteer resources](volunteer-public-resources.MD#bounties) |
| `/volunteer/leaderboard` | `GET` | Public displays, browsers, and integrations | No member session; shared `token` required only when volunteer token gating is enabled | HTML, JSON | None | `token` (query); `.json` extension or JSON `Accept` header | `Volunteer::LeaderboardController#index` | [Public volunteer resources](volunteer-public-resources.MD#leaderboard) |
| `/eventbrite/events` | `GET` | Visitors, displays and integrations | No member session or token | HTML, JSON, XML by suffix or `Accept` | None | `max_days` (default 31), `min_tickets_remaining`, `name`, `notname` | `PublicEventbriteEventsController#index` | [Public Eventbrite feed](volunteer-public-resources.MD#eventbrite-events) |

## Public runtime configuration

`GET /api/config` includes numeric `volunteer_task_max_credit`, the effective
ordinary task-creation maximum from the portal setting or existing environment
fallback (default `2.0`). This is safe public form guidance; the server remains
authoritative. Existing task edits and volunteer events remain uncapped, and
linked repair-bounty creation retains its separate maximum. Existing public
Firebase, wiki, app-domain, and optional Turnstile settings are unchanged; no
credential or private provider payload is added. See the executable
[configuration contract](../spec/api/client_config_spec.rb).

## Volunteer task weekdays and Home opportunities

Authenticated task JSON adds nullable integer `dayOfWeek` (`0` Sunday through
`6` Saturday). Admin task create/update accepts `day_of_week` (or normal camel
JSON input); omission preserves the existing value on update, while null/blank
clears it. The restriction applies only to new claims on multi-use parent tasks
and uses `America/New_York`; role authorization, CSRF, prerequisites, and
existing-claim actions are unchanged. The public `/volunteer/bounties` JSON/XML
feeds add snake-case `day_of_week` and omit tasks unavailable on the current
Eastern weekday. See [public volunteer feeds](volunteer-public-resources.MD).

`GET /api/home` still requires the current member's completed session/TOTP and
returns `private, no-store`. `availableVolunteerOpportunities` is one flat array
of up to five eligible tasks matching today's weekday, followed by up to five
other eligible tasks/events; each group sorts by credits descending, title, and
ID. All weekday-priority candidates are removed from the second pool, including
those beyond its first five. Existing active-member and claim/attendance
eligibility applies. The recommendation item shape is unchanged; no extra
weekday field or separator is added to this Home array.

Admin task/event validation errors preserve HTTP 422 and
`{status, error: "unprocessable_content", message}`, with concise human
`message` and additive `errors` field arrays. Task creation still enforces its
existing maximum; existing task edits and event credits remain uncapped. See
[task](../spec/api/volunteer_task_responses_spec.rb),
[event](../spec/api/volunteer_event_responses_spec.rb), and
[Home](../spec/api/home_spec.rb) executable contracts.

## Repository boundary

Checkout Required sheet generation uses authenticated POST endpoints at
`/api/shops/:id/checkout_required_sheet` and
`/api/tools/:id/checkout_required_sheet`, with optional `copies` (1 or 2, default
2), SVG success and JSON errors. After authentication, hidden and missing
resources return the same generic 404 before resource-scoped authorization.
These are not public download URLs. Their printed shortcode QRs resolve to the
existing public shop/tool HTML pages;
public visibility and destination authentication remain unchanged. See
[printable sheets](checkout.MD#printable-checkout-required-sheets) for permissions,
formats, errors and printing behavior.

Rails API and server-rendered routes are inventoried here. Member Portal routes
resolved by the catch-all `get '*path'` belong to `makerspace-react-2026` and
must be inventoried in that repository instead. Once the frontend inventory has
a stable location, link this inventory to it and add a reciprocal link there.

## Standard feature-document structure

Every linked feature document must use these sections, in this order:

1. **Purpose** — what the resource provides and why it is public.
2. **Canonical URL** — route pattern and preferred link form.
3. **Audience** — people, displays, scanners, or integrations it supports.
4. **Authentication and token handling** — session requirements, token source,
   precedence, comparison, and failure behavior.
5. **Identifiers and query parameters** — required and optional inputs,
   matching rules, defaults, and encoding.
6. **Formats** — representations and content negotiation.
7. **Response and error behavior** — payload/display contract and status codes.
8. **Examples** — safe, copyable requests and representative responses.
9. **Privacy considerations** — data exposed and safe deployment/link handling.
10. **Operational configuration** — settings, environment variables, caches,
    jobs, or dependencies needed to operate the resource.

Keep feature-document filenames and links consistent with the established names in this inventory.

## Repair-ticket availability and authenticated links

Public tool JSON/HTML and public shop tool lists include tool out_of_service. Public shop JSON and the nested shop in tool JSON also include the shop out_of_service flag. Shop pages, tool pages, and the fallback workshop directory show shop outage warnings. Outage notes and Slack receipts remain excluded from public projections, as do ticket data and reporter identity. Hidden restrictions are unchanged. Tool/shop HTML and JSON use public, max-age=0, s-maxage=0, must-revalidate; QR SVGs retain stable-image caching. Both shop and tool availability participate in ETags/render-cache digests.

Reservation agenda JSON reports `shopOutOfService` and `toolOutOfService`
separately, with `outOfService` true if either is true. Without a tool filter,
`toolOutOfService` is false. HTML displays the applicable shop/tool warnings while
retaining existing reservations.

`/fix-tickets`, `/fix-tickets/:id`, and `/volunteer/tasks/:id` are authenticated portal routes. Public (read-only) tickets require an active unexpired member, not an anonymous browser. Existing shortcode mappings may target the authenticated bounty detail route; resolving a shortcode does not bypass target authorization. Unauthenticated bounty feeds do not include source-ticket content.

`/tools/:id/request-checkout` and `/tools/:id/check-out-member` are authenticated app-shell routes linked from the public tool page. A signed-out visitor is redirected to `/login?return_to=` the same path, and nothing is created by visiting either. `check-out-member` is for approvers: after sign-in the app opens that tool's Workshops entry with the Check Out Member dialog. The public tool page shows its link only for tools that require a checkout.

The proposed volunteer review notification rollout uses authenticated React
links `/volunteer?task=:id` and `/volunteer?event=:id`. They select the exact task
claim (including a child claim) or event for staff review; login and existing
shop-scoped review authorization still apply. They are handled by the portal
catch-all, add no public Rails endpoint, and do not allocate shortcode records.
Background reviewer DMs build their absolute origin from `APP_DOMAIN` and require
deploying the matching Rails notification service and React selection handling.
See [the volunteer handbook](../../makerspace-react-2026/docs/VolunteerCredit.MD#notification-matrix)
and [the job inventory](jobs-tasks-services.MD#volunteer-approval-reminders).

The authenticated `DELETE /api/admin/volunteer_tasks/:id` requires an admin or
board member. It returns 204 after finalizing outstanding Slack reminders, 422
for linked ticket bounties, and 503 (`error: service_unavailable`) when final
reminder delivery cannot complete. A 503 preserves the cancelled task and
retryable receipt; retry deletion after delivery recovers. See the executable
[task response contracts](../spec/api/volunteer_task_responses_spec.rb) and
[generated API specification](../swagger/v1/swagger.json). No anonymous route is
added by this workflow.

## Authenticated checkout expiration contracts

Existing tool/group writes accept checkout_training_plan_url (blank clears);
tool writes additionally accept checkout_expiration_years (null or 1–5).
Existing serializers expose camelCase fields. Checkout responses include
expiresOn (ISO date/null), expirationRevision, expirationStatus
(active/expired/revoked/history), checkoutTrainingPlanUrl, renewedFromId,
supersededById, canManageExpiration, and canRenew. Request responses include
the requested resource's checkoutTrainingPlanUrl.

PATCH /api/admin/tool_checkouts/:id/expiration accepts expires_on (ISO date or
null) and expiration_revision, returning the updated checkout.
POST /api/admin/tools/:id/checkout_expirations accepts expires_on (future ISO
date), returning { affectedCount }. Both require a signed-in admin/board or
shop-scoped RM. Invalid input is 422, missing resources 404, unauthorized scope
403, and stale/historical individual targets 409; unauthenticated access is 401.
List status=expired/history exposes explicit views. active=true means valid
current checkouts; active=false retains its revoked-only meaning.

GET /api/admin/system_configs adds checkout.checkout_expiration_notice_days
and checkout.can_manage. PUT /api/admin/system_configs/update_setting accepts
key=checkout_expiration_notice_days and a whole-number string >=4 (admin-only).
POST /api/admin/system_configs/run_job accepts key=checkout_expiration_notice
(admin-only), returning the existing queued acknowledgment. No anonymous route
or public configuration secret is added. Portal renewal links use the existing
/tool-checkouts?mode=self-service route.

GET /api/admin/system_configs also returns the flags fob_reminder_enabled and
signup_reminder_enabled and a reminders group (fob_reminder_days,
signup_reminder_days, strings). PUT update_flag accepts the two flags, PUT
update_setting accepts the two days keys (a whole number from 1 to 14, else 422),
and POST run_job accepts key=member_reminders. Admin and board only, like the other
settings; no anonymous route is added.

PUT update_setting also accepts key=slack_conflict_scan_size (a whole number from 10 to
500, else 422; default 200), the number of Slack accounts one request of the Slack
identity conflicts check looks at. GET /api/admin/slack_identity_conflicts now returns
scan_size, live_check may be scanning, and a progress object accompanies it while a
check is under way; see jobs-tasks-services.MD. Still admin and board only.

Households: the primary of a household plan invites a second adult by email. Signed-in routes (snake_case JSON):
GET /api/household (state, seats, open invitations, whether and why not they can invite), POST /api/household/invitations
(`email`), POST /api/household/invitations/:id/resend, DELETE /api/household/invitations/:id (cancel, frees the seat),
POST /api/household/invitations/preview and POST /api/household/invitations/accept (both `token` in the body) for the invited
person, who must be signed in with the invited email. The token is never in a path or query string, so it stays out of request
logs. One public route, POST /api/household_invitations/lookup (`token`, no session), returns only the inviter's first name and
last initial, the invited email, the status and the expiry; 404 for an unknown link. Once an invitation is cancelled, expired or
used, the public lookup and the preview return only its status (no names, email or address). Invite and Resend answer 429 when
sent again within a minute or past the daily limits. The page the emailed link opens is `/household/join#token=` (public; the
token is in the URL fragment, which the browser does not send to the server: it asks the person to sign in or create a free
account, then shows the address they must match and a Join button). GET /api/invoice_options and the admin option form carry `householdSize`.
Admin POST /api/admin/groups and POST /api/admin/groups/:id/add_member return `size`, `seatsUsed`, `paymentAccepted` and invitations,
and add_member accepts `addressOverrideReason` (admin only, recorded in the audit log with both addresses).

Rentals: a rental's `status` may now be `awaiting_verification` (the member says they have vacated; the spot stays
held). DELETE /api/rentals/:id/cancel with vacated=true and POST /api/rentals/:id/mark_vacated by the rental's own
member now set it, instead of cancelling. New POST /api/rentals/:id/verify_vacated lets a resource manager,
board member or admin (not the rental's own member) confirm the space is empty: it cancels the rental. 422 unless
the rental is awaiting verification; 403 for anyone else. POST run_job also accepts key=rental_vacating_check.
Staff calling mark_vacated on another member's vacating rental still cancels it at once.

## Volunteer analytics timezone

`GET /api/admin/analytics/volunteer_summary` requires an admin or board session.
Its optional `year` filters approved credits and completed tasks using UTC calendar
year boundaries, matching the UTC month grouping regardless of the server timezone.
The pending-credit count remains global. Omitting `year` returns all-time activity.

## Eventbrite resources

The public `GET /eventbrite/events` feed includes ongoing and future occurrences from imported records.
HTML shows a thumbnail beside the title and local start time. A linked title opens the Eventbrite page in a new tab.
Events with zero tickets remaining show **SOLD OUT** in red.
See the [public feed catalog](volunteer-public-resources.MD#eventbrite-events) for eligibility, fields and examples.

`POST <EVENTBRITE_WEBHOOK_PATH>` receives private-URL Eventbrite JSON pointers,
outside session/CSRF authentication; only this receiver bypasses CSRF. It returns
202 after persistence, 200 for test, 204 for unsupported actions, 400 for malformed
payloads, 415 for non-JSON, 413 for oversized bodies and 503 for storage failure.
The receiver route is absent when the setting is blank or invalid; invalid paths
produce a nonfatal boot warning without the configured value. See the
[path requirements](eventbrite.md#configuration-and-receiver).
The real path is never published in API artifacts. `GET /api/signup_events` is
public JSON containing only eligible event IDs/names/start/timezone. Its Eastern
date window is -2/+1 calendar months, excludes private/invalid/series-parent events
and event names containing Open House. The optional organization allowlist applies
to signup choices and staff history; blank/unset includes all imported organizations.
`PUT /api/signup_source` requires a completed
member session/TOTP and normal CSRF; it completes the current provider account's
optional prompt, accepting signupSource/signupSourceDetail/signupEventbriteEventId.

Staff-only JSON index/show routes: `/api/admin/eventbrite/events`, `/orders`, and
`/attendees`, with `/:id` for details. Member history uses
`/api/admin/members/:member_id/eventbrite/orders` and `/attendees`. All require
Resource Manager, Board, or Admin, including self-history. They support zero-based
pageNum, organization_id/event_id/status/linked/search and total-items pagination.
Order filters always intersect the selected member's attendee-derived history.
Consequently, member-scoped `linked=unlinked` returns an empty list with a zero
total, including when that member has no imported attendees. The global unlinked
order browser still lists orders without any linked attendees.
Order `refundedAt` is the provider refund timestamp or its changed timestamp,
never the import time. It remains null when that date is unknown, while refund
invalidation and provider status remain visible. Existing known refund dates are
preserved on replay. The EventbriteRecord schema retains its nullable string shape.
The React `/admin/eventbrite` browser and member Eventbrite tab use these routes.
Global list requests also accept `from_date`, `to_date` and `exclude_open_house=true`.
Global orders sort by Eastern event day, earliest first, then buyer email. Undated orders come last.
Global attendees sort by email. Both email sorts are case-insensitive and apply before pagination.
The browser sends its initial Eastern date range and title exclusion on all three tabs.
See [Eventbrite](eventbrite.md).

### Eventbrite announcements configuration

The existing authenticated GET /api/admin/system_configs response adds
slack.slack_channel_upcoming_events. PUT /api/admin/system_configs/update_setting
accepts that key under the existing admin/board authorization and CSRF rules.
Blank uses upcoming-events. No public route or public /api/config field is added.
The private Eventbrite receiver's response contract is unchanged; publish/unpublish
and order notifications now also drive durable Slack announcement work.
