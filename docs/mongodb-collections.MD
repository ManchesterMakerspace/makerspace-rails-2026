# MongoDB Collections

This is the source-of-truth inventory of MongoDB collections owned by the
Rails application. Collection names are Mongoid's default pluralized model
name unless the model declares `store_in` explicitly.

## Recent collection changes (August 29–September 12, 2026)

This inventory was reconciled against the preceding two weeks of model and
index-task changes:

- `shortcodes` was added for permanent short URL mappings. Both the code and
  target URL are protected by full unique indexes.
- `slack_identity_conflicts` was added to persist unresolved or administratively
  resolved Slack/member identity conflicts.
- `invoices` gained a sparse reservation lookup index, and its transaction ID
  uniqueness contract was made explicit.
- `reservations` gained a sparse invoice lookup index.
- tool-name uniqueness changed from global uniqueness to case-insensitive
  uniqueness within a shop; the catalog query index was also added.

The table includes collections accessed without a Mongoid model: `checkins` is
queried directly by the administrative space-usage interface, and `notes` is
created/indexed by `data:ensure_unique_indexes` for legacy member notes.

Every collection has MongoDB's implicit unique `_id` index. The **Expected
indexes** column lists additional indexes declared by the application; “None”
means that only `_id` is expected. Direction `1` means ascending. Partial
conditions are included where they are part of the index contract.

| Collection | Model | Purpose | Expected indexes (in addition to `_id`) |
| --- | --- | --- | --- |
| `audit_logs` | `AuditLog` | Immutable audit events for member, billing, rental, reservation, and administrative actions. | `{ log_type: 1 }`; `{ event_type: 1 }`; `{ actor_id: 1 }`; `{ subject_id: 1 }`; `{ resource_type: 1, resource_id: 1 }`; `{ created_at: 1 }` |
| `braintree__notifications` | `BraintreeService::Notification` | Stored Braintree webhook kind, timestamp, and payload data. | None |
| `cards` | `Card` | Member access-card identifiers, holder details, expiration, and validity. | Unique `{ uid: 1 }`, partial when `uid` is a string; `{ member_id: 1 }` (deployment task) |
| `checkins` | None (direct collection access) | Facility check-in events used by administrative check-in and space-usage reporting. | None beyond `_id` is declared by this repository |
| `checkout_approvers` | `CheckoutApprover` | Members authorized to approve Safety Checkouts, optionally scoped to shops or tools. | None |
| `default_permissions` | `DefaultPermission` | Default enabled/disabled values applied to member permissions. | None |
| `earned_memberships` | `EarnedMembership` | A member's earned-membership program and its requirement/report relationships. | `{ member_id: 1 }` (deployment task) |
| `earned_membership__report` | `EarnedMembership::Report` | Periodic earned-membership reports; report-requirement snapshots are embedded in these documents. | None |
| `earned_membership__requirement` | `EarnedMembership::Requirement` | Earned-membership targets, rollover limits, and term configuration. | None |
| `earned_membership_terms` | `EarnedMembership::Term` | Progress and satisfaction state for individual earned-membership terms. | None |
| `groups` | `Group` | Household/group memberships, their primary member, subscription, and shared expiration. | Unique `{ groupName: 1 }`, partial when `groupName` is a string |
| `invoice_options` | `InvoiceOption` | Purchasable billing choices, prices, plans, promotions, and renewal operations. | None |
| `invoices` | `Invoice` | Amounts due and billing-operation state for members and other invoiceable resources. | Sparse `{ reservation_id: 1 }`; unique `{ transaction_id: 1 }`, partial when `transaction_id` is a string; `{ member_id: 1 }` (deployment task) |
| `mailtrap` | `MailtrapEvent` | Delivery events received from Mailtrap webhooks and linked back to members/messages. | `{ member_id: 1 }`; unique sparse `{ event_id: 1 }`; `{ message_id: 1 }`; `{ occurred_at: 1 }`; sparse `{ mailtrap_message_id: 1 }` |
| `mailtrap_messages` | `MailtrapMessage` | Outbound email metadata used to correlate messages with later delivery events. | Unique sparse `{ message_id: 1 }`; `{ member_id: 1 }`; `{ email: 1 }`; `{ created_at: 1 }` (the deployment task also enforces the existing member index as non-unique) |
| `members` | `Member` | Member identity, authentication, membership status, expiration, billing links, and provisioning state. | Unique `{ email: 1 }`, partial when `email` is a string; unique `{ customer_id: 1 }`, partial when `customer_id` is a string; `{ status: 1, startDate: 1, expirationTime: 1 }` |
| `membership_snapshots` | `MembershipSnapshot` | Date-stamped snapshots of members considered active for volunteer accounting. | None |
| `payments` | `Payment` | Legacy PayPal/IPN payment and subscription-event records. | `{ member_id: 1 }` (deployment task) |
| `permissions` | `Permission` | Per-member enabled/disabled permission values. | `{ member_id: 1 }` (deployment task) |
| `notes` | None (legacy/direct collection) | Legacy member notes retained and indexed by the deployment task. | `{ member_id: 1 }` (deployment task) |
| `registration_tokens` | `RegistrationToken` | One-time signup invitations carrying email, duration, and role. | None |
| `rejections` | `RejectionCard` | Rejected/unassigned access-card scans available for later assignment. | None |
| `rental_spots` | `RentalSpot` | Physical rentable locations or storage units and their rental-type configuration. | None |
| `rental_types` | `RentalType` | Rental product categories and links to invoice options. | Unique `{ display_name: 1 }`, partial when `display_name` is a string |
| `rentals` | `Rental` | A member's rental assignment, agreement, subscription, expiration, and lifecycle status. | `{ member_id: 1 }` (deployment task) |
| `reservation_blackouts` | `ReservationBlackout` | One-time or recurring periods when a shop cannot be reserved. | `{ shop_id: 1, recurrence: 1, start_date: 1, end_date: 1 }` |
| `reservations` | `Reservation` | Shop/tool reservation intervals, approval state, invoicing, and external-calendar synchronization. | Sparse `{ invoice: 1 }`; `{ shop_id: 1, status: 1, start_at: 1, end_at: 1 }`; `{ member_id: 1, status: 1, start_at: 1, end_at: 1 }`; `{ tool_ids: 1, status: 1, start_at: 1, end_at: 1 }` |
| `shortcodes` | `Shortcode` | Permanent mappings from generated short codes to deep-link target URLs. | Full unique `{ code: 1 }`; full unique `{ target_url: 1 }` |
| `shops` | `Shop` | Shop catalog, reservation rules, communication channels, and resource integrations. | Unique case-insensitive `{ name: 1 }` with `en` strength-2 collation, partial when `name` is a string |
| `slack_identity_conflicts` | `SlackIdentityConflict` | Unresolved and resolved conflicts between Slack identities and member records. | `{ slack_id: 1 }`; `{ member_id: 1 }`; `{ resolved_at: 1 }` |
| `slack_users` | `SlackUser` | Current and historical mappings between members and Slack identities. | Unique `{ member_id: 1 }`, partial for object IDs with `invalidated_at: nil`; unique `{ slack_email: 1 }`, partial for strings with `invalidated_at: nil`; unique `{ slack_id: 1 }`, partial when `slack_id` is a string |
| `system_configs` | `SystemConfig` | Runtime feature flags, settings, and tracked job-run results. | Unique `{ key: 1 }` |
| `tool_checkout_requests` | `ToolCheckoutRequest` | Member requests for a Safety Checkout and their open/closed lifecycle. | None |
| `tool_checkouts` | `ToolCheckout` | Granted or revoked member Safety Checkouts for tools. | `{ member_id: 1 }` (deployment task) |
| `tools` | `Tool` | Tool catalog, shop ownership, Safety Checkout prerequisites, and reservation rules. | Unique case-insensitive `{ shop_id: 1, name: 1 }` with `en` strength-2 collation, partial when `name` is a string; `{ shop_id: 1, name: 1, _id: 1, disabled: 1 }` with the same collation |
| `volunteer_credits` | `VolunteerCredit` | Volunteer credit awards, approvals, discounts, and reversals. | `{ member_id: 1 }` (also enforced as non-unique by the deployment task); `{ status: 1 }`; `{ created_at: 1 }` |
| `volunteer_events` | `VolunteerEvent` | Volunteer events, attendees, eligibility prerequisites, and open/closed state. | `{ status: 1 }`; unique `{ event_number: 1 }`; `{ shop_id: 1 }` |
| `volunteer_tasks` | `VolunteerTask` | Volunteer bounties/tasks, claims, verification, recurrence, and credit values. | `{ status: 1 }`; `{ claimed_by_id: 1 }`; `{ parent_task_id: 1 }`; `{ shop_id: 1 }`; unique `{ task_number: 1 }` |

`EarnedMembership::ReportRequirement` is not listed as a collection because it
is embedded inside `earned_membership__report` documents.

## Keeping indexes in sync

The table describes the indexes expected from model declarations, not a live
database inspection. After changing an index declaration, update this file and
use the repository's Mongoid index deployment process for each environment.
