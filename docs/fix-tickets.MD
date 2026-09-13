# Repair tickets and independent availability

Successful portal submissions return to the default ticket list, clearing URL filters and pagination and refreshing results. Every terminal transition (resolved, rejected, or withdrawn) stores the closer's member ObjectId in `FixTicket.closed_by_id` and creates a `ticket_closed` audit record in the same transaction. Audit failure rolls back the closure. Reopening clears the current closure attribution; prior audit records remain. Responses expose nullable `closedBy` only when someone other than the reporter closed the ticket. Reporter closures remain labeled Reporter in ordinary audit views, without their identity or request metadata. Legacy tickets without attribution show no closer.

The portal entry is `/fix-tickets`. `/fix new`, `mine`, `assigned`, `queue`, `public`, and a ticket ObjectId open private Slack modals. Both clients use the same service authorization and transitions. Ticket list queries are server-paginated and scoped before filtering.

## Data and privacy

The Bounty Tasks section of `/admin/system-settings` includes `ticket_bounty_max_credit` (default 2), separate from the ordinary task-creation maximum. It limits ticket-to-bounty conversions and is returned as `bountyMaxCredit` in the ticket catalog. Setting edits use the portal audit log. Admin/board edits of existing bounty tasks may set any positive finite credit value without an upper cap; credit changes record actor, task ID/title, and before/after credits in the portal audit log. Existing awarded volunteer credits are not rewritten.

Acknowledged admin reporter reveals also create a general audit record containing the ticket ObjectID, title, and acting admin. No reporter identity, subject, or ticket snapshot containing reporter data is included. The separate restricted reveal record is retained; the reveal response is withheld if the general audit record cannot be saved.

`FixTicketService` requires MongoDB transactions on a replica set. Its reporter write lock participates in the transaction, serializing cap checks, current-role checks, priority insertion, ticket changes, and bounty linkage. Do not run this feature on standalone MongoDB. Use `fix_tickets:ensure_indexes` before accepting submissions. The admin security settings page exposes `ticket_open_limit` (default 10).

Reporter identity is excluded by explicit presenters. Reveal is a separate admin-only acknowledged, no-store action recorded in `fix_ticket_reveals`. Restrict operational collection access and backups accordingly. User-authored text may identify its author. Reporter reward credits are excluded from general credit administration and reviewed through ticket capabilities by a different authorized reviewer.

`Tool.disabled` retains existing Hidden behavior. `Tool.out_of_service` defaults false and is changed separately under the same shop lock used by reservations. Closing tickets does not restore service. Existing reservations and billing remain intact; the outage response identifies affected reservations for staff review.

## Slack delivery

Reporters cannot claim their own linked repair bounties, including privileged reporters. Staff assignment edits preserve bounty-derived assignments; release/rejection removes them while retaining manual grants. Linked release/rejection notifications and canvas refreshes occur only after the ticket/bounty transaction commits. Generic volunteer-task API responses include nullable `ticketId`; source ticket access is independently authorized.

Slack filter dialogs retain selected tool and assignee IDs when changing other filters. Shop-linked bounty creation and automatic cancellation refresh the volunteer canvas after commit. Direct cancellation of a claimed or pending linked bounty is blocked under the ticket transaction lock: release the claim or reject pending work first so claim-derived ticket access is removed by the existing cleanup flow.

Configure the optional `SLACK_TICKETS_CHANNEL` only after testing the destination. Full ticket notes are visible to channel participants, including notes on otherwise private tickets. Human thread replies are not imported. Shop/tool announcements are independently opt-in and contain designated summaries only.

Events and recipients are saved in the mutation transaction. Per-ticket delivery jobs preserve revision order; delivery receipts and pre-send intents are persisted without changing ticket timestamps. Uncertain sends reconcile Slack history by stable client message ID before resending. A history permission or network failure keeps the event pending rather than assuming deletion. Invite the bot to destination channels and grant the history scopes in the manifest. Thread reconciliation must be exercised against the workspace token in staging; missing history access must be resolved before enabling publication.

Run `fix_tickets:recover_deliveries` every five minutes if using an external scheduler. `config/schedule.rb` includes the equivalent scheduled job. Disabling the central variable stops pending central sends; events created while disabled are not backfilled. Existing roots retain string timestamps, resolved channel IDs, and workspace IDs; a destination change establishes a new root on the next eligible event.

## Deployment order and staging

### Local MongoDB transaction support

Specs needing real transactions are tagged `requires_transactions: true`. RSpec checks MongoDB topology and reports these examples as skipped/pending (non-fatal) on standalone servers. They run normally, with failures remaining fatal, on transaction-capable replica sets/sharded clusters. Nontransactional tests, including the transaction-unavailable error regression, still run everywhere. Connection/authentication errors are not converted into skips. To explicitly exclude this optional group, run `bundle exec rspec --tag ~requires_transactions`; use a replica-set CI run to retain concurrency/atomicity coverage.

A standalone `mongod` cannot execute multi-document transactions. Repair writes return HTTP 503 with a JSON `error` containing the full `TransactionsNotSupported` message and replica-set setup guidance; the portal displays this message and retains the form for retry. Other MongoDB exceptions are not exposed verbatim. There is no nontransactional fallback, because it could leave priorities, bounty publication, and the notification outbox partially saved.

For a local test server, a single-node replica set is sufficient. Stop the existing test `mongod` cleanly, keep its existing data directory, and restart it with its existing options plus `--replSet rs0` (or add `replication.replSetName: rs0` to its MongoDB configuration). Do not start a second process on that directory. Initialize once from `mongosh`:

```javascript
rs.initiate({ _id: "rs0", members: [{ _id: 0, host: "localhost:27017" }] })
```

Wait until `db.hello().isWritablePrimary` returns `true`. For Rails running on the same host, set `MLAB_URI=mongodb://localhost:27017/makerspace_test?replicaSet=rs0`, restart Rails, and run `bundle exec rake fix_tickets:ensure_indexes`. Preserve your actual database name, credentials, and other URI options. If Rails or MongoDB runs in Docker, use a replica-set member hostname and port reachable from both MongoDB and Rails instead of `localhost`; the URI must use that reachable address too. Single-node configuration provides transactions, not failover redundancy.

### Rollout

1. Deploy additive Rails models, services, indexes, and jobs before exposing the portal and Slack entry points. Run `bundle exec rake fix_tickets:ensure_indexes` with the deployment database configuration.
2. Purge managed/CDN caches for public shop and tool HTML/JSON. Their new responses require revalidation. Previously fresh browser responses can remain until their original three-day freshness expires. QR SVG caching stays separate.
3. Deploy the portal assets, update Slack command/interactivity URLs from the manifest for the staging host, and verify signatures and workspace identity. Keep publication disabled initially.
4. Exercise role scopes, cap/concurrency, anonymous reward review, bounty claim/release, all four Hidden/out-of-service combinations, public QR-linked pages, and reservation edits in staging.
5. Test central root creation/deletion recovery, uncertain sends, destination changes, full notes, broadcasts, and DMs with staging members. Enable the production publication variable only after these checks pass.

Local verification uses an isolated MongoDB replica set and mocked Slack. `spec/services/fix_ticket*_spec.rb`, `spec/services/tool_availability_spec.rb`, `spec/requests/fix_tickets_spec.rb`, and `spec/api/fix_tickets_spec.rb` cover the domain/API. Regenerate Swagger with `bundle exec rake rswag:specs:swaggerize`. In React, run `npm run typecheck`, `npm run build`, and `node scripts/check_fix_tickets.cjs` for the isolated browser fixture at 320, 600, 900, and 1440 px. Live workspace delivery and staging deployment are operational checks, not performed by these local tests.

Ticket titles and ad-hoc tool names accept ASCII letters, digits, spaces, and `. , _ ( ) / -`. The API rejects other characters on creation or when these fields change. Existing names are not rewritten, and free-form descriptions and notes remain supported.

Linked-bounty claims require the prerequisite tool checkouts even for admins, board members, and RMs. Staff assignment edits retain existing manual grants without converting claim-only grants to manual ones; releasing the claim therefore removes only its derived access. Authenticated ticket, outage, bounty-detail, and system-config operations declare the `_member-interface_session` cookie through the OpenAPI `sessionAuth` scheme. The executable system-config contract documents `security.ticket_open_limit` and its admin-only positive-integer update.

The catalog includes a creation-unavailable reason for deep-linked reporting dialogs. Authenticated bounty detail returns viewer-specific claim/completion capabilities and is not cacheable. Central Slack replies include only state, confirmation, assignments, discussion notes, announcement notes, and bounty activity; edits to unrelated ticket fields are not published. Reusable OpenAPI schemas describe ticket pages/details, capabilities/history, catalog data, reveal results, and affected reservations.
