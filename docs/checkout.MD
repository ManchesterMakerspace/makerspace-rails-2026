# Safety checkouts

## Member Portal lists

“My Active Tool Checkouts” displays an accessible note tooltip beside tools with
nonblank notes. Active checkout holders can see notes for their hidden tools;
revoked checkouts alone do not grant note access.

The roster's “Check Out Member” search sends `fully_active_unexpired=true` to
`GET /api/members`. Mongo filters to `status: activeMember` and an expiration
strictly later than the current Unix time in milliseconds before search paging.
This opt-in filter does not change checkout creation or Slack eligibility.

Shop, tool, approver, and checkout responses use request-scoped batched lookups.
Shop tool counts and prerequisite labels share a Mongo `$facet` aggregation.
The page shares lazy catalog reads across tabs and refreshes loaded catalogs on
mutations and window focus. Public and management catalogs remain separate.
No persistent cache stores tool notes or authorization decisions.

## Mongo queries and deployment indexes

`CheckoutInteractionQuery` scopes requestable tools in Mongo by `shop_id`,
`disabled != true`, and `open != true`, then orders by `name` and `_id` with
`{ locale: "en", strength: 2 }` collation. Enabled shops use the same
case-insensitive alphabetical ordering. Existing checkout IDs, active
prerequisite checkout IDs, and open-request tool IDs are fetched in bulk and
passed to `ToolCheckoutRequestEligibility`; there is no per-candidate `exists?`
or `pluck`. The policy remains the final validator immediately before insertion.

Open-request queries constrain `status: "open"` and authorized member/tool IDs
in Mongo. Eligible member IDs come from status/expiration filters, without
loading every member. Pending IDs are paired only with tools allowing pending
members. Visible requests are oldest first (`request_date: 1, _id: 1`), with the
ID providing a stable tie-breaker. Bulk checkout data also removes requests with
unmet prerequisites or an existing disqualifying checkout.

Deploy all six declared nonunique indexes from the application root with:

```sh
RAILS_ENV=production bundle exec rake data:ensure_checkout_indexes
```

| Collection | Index fields, in order (all ascending) |
| --- | --- |
| `members` | `status, expirationTime` |
| `tool_checkouts` | `member_id, revoked_at, tool_id` |
| `checkout_approvers` | `member_id` |
| `tool_checkout_requests` | `member_id, status, request_date, _id` |
| `tool_checkout_requests` | `tool_id, status, request_date, _id` |
| `tools` | `shop_id, name, _id, disabled, open` (case-insensitive collation) |

The tool index places shop equality and name ordering before availability
inequalities. A test-database explain comparison with 6,000 synthetic tools
returned the same 343 results without a blocking sort for either index; including
`open` reduced fetched documents from 514 to 343, with 601 keys examined in both
plans. This is fixture evidence, not a production workload benchmark.

The deployment task in `lib/tasks/checkout_indexes.rake` is repeatable and uses
model declarations. It never drops indexes or changes documents. A conflict on
a targeted index stops the task for review. Use it instead of global
`db:mongoid:create_indexes`, which may encounter unrelated legacy identity-index
conflicts such as `cards.uid_1`. Existing documents need no migration.

## Slack commands

Command acknowledgements, help, and status lists are visible only to the
caller. The request and approval workflows can additionally send the DMs and
channel announcements described below.

Bare `/checkout` opens the same four-choice menu for members and approvers:
**View my checkouts**, **Request a checkout**, **Volunteer to do checkouts**, and **View open requests**. In a configured
shop channel that shop is fixed for the entire modal session. Elsewhere the
initial view offers enabled shops in case-insensitive alphabetical order; once
chosen, the shop cannot be switched within that session. Close and reopen the
command to choose another shop. Legacy textual approvals still require a shop
channel. An unknown Slack identity is synchronized once before an account-link
message is returned. Expired, revoked, suspended, inactive and otherwise
ineligible members receive distinct membership guidance. Pending members can
enter, but can only interact with tools allowing pending members.

| Command | Behavior |
| --- | --- |
| `/checkout` | Opens the checkout menu and, outside a shop channel, an enabled-shop selector. |
| `/checkout @member tool-name` | An authorized approver checks out the mentioned member on a tool in the current shop channel. An email address may replace the mention. |
| `/checkout request` | In a shop channel, opens a request modal containing only eligible tools without an existing open request. Outside a shop channel, lists all of the caller's open requests across shops. |
| `/checkout request tool-name` | Requests the named tool in the current shop channel after rechecking eligibility. |
| `/checkout active` or `/checkout list` | In a shop channel, lists the caller's available active checkouts using the same alphabetical ordering and detail fields as the modal, without the redundant shop line. Outside a shop channel, behaves like `active all`. |
| `/checkout active all` | Lists available active checkouts across enabled shops using the shared query and detail formatter. Each entry identifies its shop. |
| `/checkout volunteer` | Opens the volunteer flow. A member in good standing may request approver access for any tool on which they have an active checkout. |
| `/checkout help` | Shows the commands available to the linked caller, including textual approval only for callers with approval authority. |

Members with a checkout in the current shop are encouraged to volunteer as
checkout approvers for tools they know well. The request accepts an optional note and asynchronously DMs each RM for
the containing shop with that note, the tool checkout date, and the member's join date and appears ahead of ordinary requests in that shop's **View
open requests** list. An assigned shop RM, or an admin/board member tagged as a contact for that shop, may approve or decline it, with an optional decision note. Approval adds an
individual-tool `CheckoutApprover` assignment. Either decision DMs the requester with the status and RM note. A resource manager (RM) is
implicitly an approver for every tool in each shop they manage. Approval and decline are serialized with the same per-member/tool lock used by checkout mutations, and the request is reloaded under that lock. Concurrent reviewer decisions therefore cannot both apply or leave a declined request with approver access, and checkout revocation uses that same lock so it cannot race a grant.

## Stateful Slack modal

`SlackCheckoutModal` renders callback `checkout_modal`; `SlackCheckoutWorkflow`
handles `block_actions` and `view_submission`. The legacy
`checkout_request_submit` submission callback remains supported separately.

Stable selector block IDs are `checkout_menu`, `checkout_shop`, `checkout_tool`,
`checkout_request`, and `checkout_checkout`; their action IDs append `_select`.
The note input uses `checkout_note` for both IDs. The `checkout_actions` block
contains `checkout_edit_note`, `checkout_cancel_request`, and
`checkout_approve_request` buttons when authorized, plus
`checkout_approve_volunteer` for an RM reviewing a volunteer. `checkout_navigation`
contains `checkout_back`.

Private metadata is integrity-protected and expires after one hour. Its payload
contains only `member_id`, optional `shop_id`, the original `response_url`,
`slack_user_id`, `step`, and optional `record_id`. Neither notes nor permission
flags are cached there. Each transition checks the Slack identity against its
current member link, reloads selected records, checks membership and shop/tool
availability, and rechecks ownership or current approval assignments. Option
labels are display-only; notes come exclusively from the note input value.

Open requests combine the member's own eligible requests with this approval scope:

| Acting member | Additional visible requests |
| --- | --- |
| Ordinary member | None |
| Admin or board member | Every eligible request in the selected shop |
| Resource manager | Eligible requests in the selected shop, if they manage it |
| Assigned tool approver | Eligible requests for assigned tools or assigned shops, within the selected shop |

Assignments are additive, but never expose another shop's requests in the current
modal. Expired, inactive, revoked, suspended and otherwise ineligible requesters
are excluded; pending requesters remain only where the tool allows pending.
Lists are oldest first, with `_id` breaking equal request dates.

Only the owner may edit or cancel a request. Owner details show tool, requested
date and note with Edit note, Cancel request and Go back. Notes are limited to
128 characters. Other members' details
include requester and shop and offer only Approve and Go back. Approval and
cancellation buttons open confirmation views; writes happen on submission.
Request creation, note editing, cancellation and approval share the existing
per-member/tool Redis request lock and revalidate inside it. Successful approval
creates a Slack-signed-off checkout and closes the request synchronously.
`CheckoutNotificationJob` then performs the users-channel invitation, checkout
DM, success announcement and audit logging in the background. Request
announcements (including legacy modal submissions) and cancellation announcement
updates also run in that job. No Slack notification API call runs before the
interaction acknowledgement. Successful writes enqueue final outcome
delivery before returning `response_action: "clear"`, including when enqueueing
fails. Notification failure never undoes a saved request or checkout.

Block navigation uses `views.update` with the incoming view hash. A failed update
is never retried without that hash; the handler attempts a separate explanatory
alert and acknowledges the interaction. Submission note errors stay next to the
note input; stale records and authorization changes replace the view with an
explanation. Navigation reloads records even when going back.

## Request eligibility

A tool can be newly requested only when all of the following are true:

- it requires a checkout (`open != true`) and both the tool and its shop are
  enabled; disabled/hidden/out-of-service resources are unavailable;
- the member is active and unexpired, or is pending and the tool explicitly
  permits pending members;
- every tool ID in `Tool#prerequisite_ids` has a non-revoked checkout for the
  member;
- the member has no checkout record for the target tool, including a revoked
  record; and
- there is no open checkout request for that member and tool.

The portal, named Slack request job, Slack modal, and Slack modal submission
all use `ToolCheckoutRequestEligibility`. Eligible tools are displayed in
case-insensitive alphabetical order. Submission checks again so changes made
after the modal opened cannot create an invalid request. Slack displays at
most 100 selectable static options; when more than 100 tools are eligible it
directs the member to the portal instead of silently omitting tools.

## Checkout approvers

Board members and admins can approve every tool. RMs can approve every tool in
the shops they manage. An additional checkout approver is a member with a
`CheckoutApprover` record assigning one or more complete shops and/or
individual tools; shop and tool assignments are additive. Outside those
assignments, an additional approver has no checkout authority. All creation paths reject disabled tools and shops, ineligible membership, unmet
prerequisites and existing checkout records. Portal, textual Slack approvals and
the modal all use `CheckoutCreation` under the same per-member/tool lock.

When an additional checkout approver completes a checkout, the application
silently creates an auto-approved `0.25` volunteer credit for that approver.
This does not apply when the checkout is completed under admin, board-member,
or RM authority, and it does not send the normal volunteer-credit award DM.
The credit also retains the checkout ID and the checkout retains the credit ID for idempotent recovery and auditing. If the checkout is later
revoked, a silent `-0.25` reversal record offsets that exact credit and the
original credit is marked reversed. If the original credit contributed to a Braintree discount, the normal treasurer review notification is retained even though the member-facing reversal DM remains suppressed.

A member's active checkout list appends `:a:` to tools for which that member is
an additional checkout approver. Tool details state either that the member is
an approver or that an approver volunteer request is pending. Non-reservable
tools omit `Reservable: No`; reservable tools still show `Reservable: Yes`.

Revoking a checkout also removes that member's individual approver assignment
for the tool and marks open volunteer requests for that member/tool as revoked.
Shop-wide assignments are not altered; an otherwise-empty approver record is removed.

## Slack notifications and announcements

### Requests

- Creating a request posts a channel message only when the tool has `announce`
  enabled. It goes to the tool's `announce_channel` when configured, otherwise
  to the shop's `slack_channel`. The message identifies the member, tool, shop,
  and optional request note.
- A successful legacy `checkout_request_submit` submission queues a confirmation
  explaining that unpaid volunteers process checkouts and identifying tagged
  resource managers they can contact about becoming an assistant checkout
  approver. It replaces the ephemeral acknowledgement first, with DM fallback;
  delivery failure does not undo the saved request.
- Cancelling an announced request updates that same channel message; it does
  not post a second announcement. If approval or cancellation races an in-flight
  request announcement, both senders atomically retain the first recorded Slack
  timestamp. The retained message is updated to the final state, and a redundant
  late post is deleted rather than replacing the stored success timestamp. The submitting owner receives the asynchronous
  final outcome described below, with DM fallback if replacement fails.

- Creating an approver volunteer request DMs every assigned RM for the tool's
  shop, identifying the volunteer, tool, shop, optional note, checkout date, and
  makerspace join date and directing the RM to **View open requests**. Suppressed or unlinked RM notifications are skipped, and a
  delivery failure does not undo the saved request.
- Approving or declining a volunteer request sends the requester a DM with the
  resulting status and the RM's optional decision note.

### Approvals

- A newly checked-out member receives a DM identifying the tool, shop, and
  approver, plus private tool notes when present. Direct notifications are
  suppressed for members whose notification policy disables them.
- If tool announcements are enabled, success is posted to the tool's
  `announce_channel`, falling back to the shop's `slack_channel`. When the
  approval closes an announced request, the existing request message is
  updated where possible.
- If the tool has a `users_channel`, success is also posted there and the
  member is invited to that channel. A failed automatic invitation is called
  out in the success message so it can be completed manually.

### Revocations

- The member whose checkout is revoked receives a DM naming the tool and shop,
  but the internal revocation reason is not included. The member is removed
  from the tool's users channel when one is configured.
- When somebody other than the original approver revokes the checkout, the
  original approver also receives a DM only if they are still authorized for
  that tool as an additional approver, the shop RM, a board member, or an
  admin. The DM identifies the shop, tool, original checkout date, checked-out
  member (Slack mention when available, otherwise full name), and whether the
  revoker acted as an RM, board member, admin, or checkout approver.
- The revoker's name is withheld from an ordinary additional approver or RM.
  It is included only when the original approver receiving the DM is currently
  a board member or admin.
- Checkout creation and revocation also write operational audit messages to
  the configured Slack logs channel.

## Active checkout details and outcome delivery

The modal and `/checkout active` share `listed_active_checkouts` and
`CheckoutDisplay`. The Mongo query requires the caller's member ID, no revocation,
and tools in the chosen shop; available tools are ordered using case-insensitive
collation. Tools and shops are loaded in bulk. Empty lists retain Go back.
Details recheck ownership, shop and current activity before showing tool name,
description, authorized notes, users channel, effective wiki URL, checkout date,
reservability when true, and approver or pending-volunteer status, plus Go back. The date comes from `checked_out_at`. Modal fields are truncated to Block Kit limits; textual
responses escape user-controlled Slack formatting and bound message length.

Final checkout outcomes use the original response URL asynchronously, replacing
the initial slash-command acknowledgement using `replace_original: true`,
`response_type: "ephemeral"`, and the final text. Non-2xx responses and request
exceptions count as replacement failures. Replacement failures fall
back to a DM to the submitting Slack user. Enqueue, replacement and DM failures
are reported without the response URL and never undo persisted requests or
checkouts. Outcome job credentials are encrypted and job argument logging is
disabled. See `docs/jobs-tasks-services.MD` for timeouts and delivery details.
