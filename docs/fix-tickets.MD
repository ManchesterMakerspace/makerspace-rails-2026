# Repair tickets and independent availability

The portal entry is `/fix-tickets`. `/fix new`, `mine`, `assigned`, `queue`, `public`, and a ticket ObjectId open private Slack modals. Both clients use the same service authorization and transitions. Ticket list queries are server-paginated and scoped before filtering.

## Data and privacy

`FixTicketService` requires MongoDB transactions on a replica set. Its reporter write lock participates in the transaction, serializing cap checks, current-role checks, priority insertion, ticket changes, and bounty linkage. Do not run this feature on standalone MongoDB. Use `fix_tickets:ensure_indexes` before accepting submissions. The admin security settings page exposes `ticket_open_limit` (default 10).

Reporter identity is excluded by explicit presenters. Reveal is a separate admin-only acknowledged, no-store action recorded in `fix_ticket_reveals`. Restrict operational collection access and backups accordingly. User-authored text may identify its author. Reporter reward credits are excluded from general credit administration and reviewed through ticket capabilities by a different authorized reviewer.

`Tool.disabled` retains existing Hidden behavior. `Tool.out_of_service` defaults false and is changed separately under the same shop lock used by reservations. Closing tickets does not restore service. Existing reservations and billing remain intact; the outage response identifies affected reservations for staff review.

## Slack delivery

Configure the optional `SLACK_TICKETS_CHANNEL` only after testing the destination. Full ticket notes are visible to channel participants, including notes on otherwise private tickets. Human thread replies are not imported. Shop/tool announcements are independently opt-in and contain designated summaries only.

Events and recipients are saved in the mutation transaction. Per-ticket delivery jobs preserve revision order; delivery receipts and pre-send intents are persisted without changing ticket timestamps. Uncertain sends reconcile Slack history by stable client message ID before resending. A history permission or network failure keeps the event pending rather than assuming deletion. Invite the bot to destination channels and grant the history scopes in the manifest. Thread reconciliation must be exercised against the workspace token in staging; missing history access must be resolved before enabling publication.

Run `fix_tickets:recover_deliveries` every five minutes if using an external scheduler. `config/schedule.rb` includes the equivalent scheduled job. Disabling the central variable stops pending central sends; events created while disabled are not backfilled. Existing roots retain string timestamps, resolved channel IDs, and workspace IDs; a destination change establishes a new root on the next eligible event.

## Deployment order and staging

1. Deploy additive Rails models, services, indexes, and jobs before exposing the portal and Slack entry points. Run `bundle exec rake fix_tickets:ensure_indexes` with the deployment database configuration.
2. Purge managed/CDN caches for public shop and tool HTML/JSON. Their new responses require revalidation. Previously fresh browser responses can remain until their original three-day freshness expires. QR SVG caching stays separate.
3. Deploy the portal assets, update Slack command/interactivity URLs from the manifest for the staging host, and verify signatures and workspace identity. Keep publication disabled initially.
4. Exercise role scopes, cap/concurrency, anonymous reward review, bounty claim/release, all four Hidden/out-of-service combinations, public QR-linked pages, and reservation edits in staging.
5. Test central root creation/deletion recovery, uncertain sends, destination changes, full notes, broadcasts, and DMs with staging members. Enable the production publication variable only after these checks pass.

Local verification uses an isolated MongoDB replica set and mocked Slack. `spec/services/fix_ticket*_spec.rb`, `spec/services/tool_availability_spec.rb`, `spec/requests/fix_tickets_spec.rb`, and `spec/api/fix_tickets_spec.rb` cover the domain/API. Regenerate Swagger with `bundle exec rake rswag:specs:swaggerize`. In React, run `npm run typecheck`, `npm run build`, and `node scripts/check_fix_tickets.cjs` for the isolated browser fixture at 320, 600, 900, and 1440 px. Live workspace delivery and staging deployment are operational checks, not performed by these local tests.

Ticket titles and ad-hoc tool names accept ASCII letters, digits, spaces, and `. , _ ( ) / -`. The API rejects other characters on creation or when these fields change. Existing names are not rewritten, and free-form descriptions and notes remain supported.
