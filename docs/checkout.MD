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

Deploy the declared nonunique indexes with `bundle exec rake data:ensure_checkout_indexes`:
`members(status, expirationTime)`, `tool_checkouts(member_id, revoked_at, tool_id)`,
and `checkout_approvers(member_id)`. Existing documents need no migration.
The task is repeatable and creates only these three indexes; it never drops
indexes or changes documents. If a targeted index conflicts, it stops for review.
Use this task rather than the global `db:mongoid:create_indexes` for checkout
deployment: the global task can fail on unrelated legacy identity indexes, such
as a full unique `cards.uid_1` conflicting with the model's partial unique index.
That legacy index can remain in place while the checkout indexes are installed.

## Slack commands

Command acknowledgements, help, and status tables are visible only to the
caller. The request and approval workflows can additionally send the DMs and
channel announcements described below.

Bare `/checkout` opens the same three-choice menu for members and approvers:
View my checkouts, Request a checkout, and View open requests. In a configured
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
| `/checkout request` | In a shop channel, opens a request modal containing eligible tools and separately marks tools with an existing open request. Outside a shop channel, lists all of the caller's open requests across shops. |
| `/checkout request tool-name` | Requests the named tool in the current shop channel after rechecking eligibility. |
| `/checkout active` | In a shop channel, displays an alphabetized table of the caller's active checkouts there, including whether each tool is enabled and whether the caller can approve it. Outside a shop channel, behaves like `active all`. |
| `/checkout active all` | Displays one alphabetized table per shop where the caller has an active checkout. Shops and tools are alphabetized, and every heading includes the shop's configured Slack channel. |

Members with a checkout in the current shop are encouraged to volunteer as
checkout approvers for tools they know well. A resource manager (RM) is
implicitly an approver for every tool in each shop they manage.

## Stateful Slack modal

`SlackCheckoutModal` renders callback `checkout_modal`; `SlackCheckoutWorkflow`
handles `block_actions` and `view_submission`. The legacy
`checkout_request_submit` submission callback remains supported separately.

Stable selector block IDs are `checkout_menu`, `checkout_shop`, `checkout_tool`,
`checkout_request`, and `checkout_checkout`; their action IDs append `_select`.
The note input uses `checkout_note` for both IDs. The `checkout_actions` block
contains `checkout_edit_note`, `checkout_cancel_request`, and
`checkout_approve_request` buttons when authorized. `checkout_navigation`
contains `checkout_back`.

Private metadata is integrity-protected and expires after one hour. Its payload
contains only `member_id`, optional `shop_id`, the original `response_url`,
`slack_user_id`, `step`, and optional `record_id`. Neither notes nor permission
flags are cached there. Each transition checks the Slack identity against its
current member link, reloads selected records, checks membership and shop/tool
availability, and rechecks ownership or current approval assignments. Option
labels are display-only; notes come exclusively from the note input value.

Open requests combine the member's own eligible requests and their authorized
approval queue. Only the owner may edit or cancel a request. Approval and
cancellation buttons open confirmation views; writes happen on submission.
Request creation, note editing, cancellation and approval share the existing
per-member/tool Redis request lock and revalidate inside it. Successful approval
creates a Slack-signed-off checkout, closes the request, and invokes the existing
checkout notifications and audit logging. Completion stays in the modal.

Block navigation uses `views.update` with the incoming view hash. A failed update
is never retried without that hash; the handler attempts a separate explanatory
alert and acknowledges the interaction. Submission note errors stay next to the
note input; stale records and authorization changes replace the view with an
explanation. Navigation reloads records even when going back.

## Request eligibility

A tool can be newly requested only when all of the following are true:

- it requires a checkout and both the tool and its shop are enabled;
- the member is active and unexpired, or is pending and the tool explicitly
  permits pending members;
- every tool ID in `Tool#prerequisite_ids` has a non-revoked checkout for the
  member;
- the member has no checkout record for the target tool, including a revoked
  record; and
- there is no open checkout request for that member and tool.

The portal, named Slack request job, Slack modal, and Slack modal submission
all use the same eligibility policy. Submission checks again so changes made
after the modal opened cannot create an invalid request. Slack displays at
most 100 selectable static options; when more than 100 tools are eligible it
directs the member to the portal instead of silently omitting tools.

## Checkout approvers

Board members and admins can approve every tool. RMs can approve every tool in
the shops they manage. An additional checkout approver is a member with a
`CheckoutApprover` record assigning one or more complete shops and/or
individual tools; shop and tool assignments are additive. Outside those
assignments, an additional approver has no checkout authority. The modal rejects disabled tools and shops for every role. Legacy portal/text
approvals retain their existing RM, board and admin handling of disabled tools.

## Slack notifications and announcements

### Requests

- Creating a request posts a channel message only when the tool has `announce`
  enabled. It goes to the tool's `announce_channel` when configured, otherwise
  to the shop's `slack_channel`. The message identifies the member, tool, shop,
  and optional request note.
- A successful legacy `checkout_request_submit` submission also DMs the requester to confirm that
  unpaid volunteers process checkouts and identifies tagged resource managers
  they can contact about becoming an assistant checkout approver. Failure to
  deliver this confirmation does not undo the saved request.
- Cancelling an announced request updates that same channel message; it does
  not post a second message or send a DM.

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
