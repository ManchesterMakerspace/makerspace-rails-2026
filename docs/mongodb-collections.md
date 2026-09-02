# MongoDB Collections

This is the source-of-truth inventory of MongoDB collections owned by the
Rails application. Collection names are Mongoid's default pluralized model
name unless the model declares `store_in` explicitly.

### Warning
This does not yet document indexes installed by the deployment task.  

The table omits the non-unique `{ member_id: 1 }` index that `data:ensure_unique_indexes` creates on `cards`; the same omission affects `earned_memberships`, `invoices`, `payments`, `permissions`, `rentals`, and `tool_checkouts`. Because both the Procfile and Dockerfile run that task before starting the application, these are application-declared expected indexes rather than incidental live-database state, and entries such as `permissions: None` are incorrect. \n \n Include non-model collections in the source-of-truth table\nThis is not a complete inventory of collections used by the Rails application: `Admin::CheckinsController` and `Admin::SpaceUsageController` directly query `Mongoid.default_client[:checkins]`, while `data:ensure_unique_indexes` explicitly creates/indexes the `notes` collection. Neither appears in the table below.


Every collection has MongoDB's implicit unique `_id` index. The **Expected
indexes** column lists additional indexes declared by the application; “None”
means that only `_id` is expected. Direction `1` means ascending. Partial
conditions are included where they are part of the index contract.

| Collection | Model | Purpose | Expected indexes (in addition to `_id`) |
| --- | --- | --- | --- |
| `audit_logs` | `AuditLog` | Immutable audit events for member, billing, rental, reservation, and administrative actions. | `{ log_type: 1 }`; `{ event_type: 1 }`; `{ actor_id: 1 }`; `{ subject_id: 1 }`; `{ resource_type: 1, resource_id: 1 }`; `{ created_at: 1 }` |
| `braintree__notifications` | `BraintreeService::Notification` | Stored Braintree webhook kind, timestamp, and payload data. | None |
| `cards` | `Card` | Member access-card identifiers, holder details, expiration, and validity. | Unique `{ uid: 1 }`, partial when `uid` is a string |
| `checkout_approvers` | `CheckoutApprover` | Members authorized to approve Safety Checkouts, optionally scoped to shops or tools. | None |
| `default_permissions` | `DefaultPermission` | Default enabled/disabled values applied to member permissions. | None |
| `earned_memberships` | `EarnedMembership` | A member's earned-membership program and its requirement/report relationships. | None |
| `earned_membership__report` | `EarnedMembership::Report` | Periodic earned-membership reports; report-requirement snapshots are embedded in these documents. | None |
| `earned_membership__requirement` | `EarnedMembership::Requirement` | Earned-membership targets, rollover limits, and term configuration. | None |
| `earned_membership_terms` | `EarnedMembership::Term` | Progress and satisfaction state for individual earned-membership terms. | None |
| `groups` | `Group` | Household/group memberships, their primary member, subscription, and shared expiration. | Unique `{ groupName: 1 }`, partial when `groupName` is a string |
| `invoice_options` | `InvoiceOption` | Purchasable billing choices, prices, plans, promotions, and renewal operations. | None |
| `invoices` | `Invoice` | Amounts due and billing-operation state for members and other invoiceable resources. | Unique `{ transaction_id: 1 }`, partial when `transaction_id` is a string |
| `mailtrap` | `MailtrapEvent` | Delivery events received from Mailtrap webhooks and linked back to members/messages. | `{ member_id: 1 }`; unique sparse `{ event_id: 1 }`; `{ message_id: 1 }`; `{ occurred_at: 1 }`; sparse `{ mailtrap_message_id: 1 }` |
| `mailtrap_messages` | `MailtrapMessage` | Outbound email metadata used to correlate messages with later delivery events. | Unique sparse `{ message_id: 1 }`; `{ member_id: 1 }`; `{ email: 1 }`; `{ created_at: 1 }` |
| `members` | `Member` | Member identity, authentication, membership status, expiration, billing links, and provisioning state. | Unique `{ email: 1 }`, partial when `email` is a string; unique `{ customer_id: 1 }`, partial when `customer_id` is a string; `{ status: 1, startDate: 1, expirationTime: 1 }` |
| `membership_snapshots` | `MembershipSnapshot` | Date-stamped snapshots of members considered active for volunteer accounting. | None |
| `payments` | `Payment` | Legacy PayPal/IPN payment and subscription-event records. | None |
| `permissions` | `Permission` | Per-member enabled/disabled permission values. | None |
| `registration_tokens` | `RegistrationToken` | One-time signup invitations carrying email, duration, and role. | None |
| `rejections` | `RejectionCard` | Rejected/unassigned access-card scans available for later assignment. | None |
| `rental_spots` | `RentalSpot` | Physical rentable locations or storage units and their rental-type configuration. | None |
| `rental_types` | `RentalType` | Rental product categories and links to invoice options. | Unique `{ display_name: 1 }`, partial when `display_name` is a string |
| `rentals` | `Rental` | A member's rental assignment, agreement, subscription, expiration, and lifecycle status. | None |
| `reservation_blackouts` | `ReservationBlackout` | One-time or recurring periods when a shop cannot be reserved. | `{ shop_id: 1, recurrence: 1, start_date: 1, end_date: 1 }` |
| `reservations` | `Reservation` | Shop/tool reservation intervals, approval state, and external-calendar synchronization. | `{ shop_id: 1, status: 1, start_at: 1, end_at: 1 }`; `{ member_id: 1, status: 1, start_at: 1, end_at: 1 }`; `{ tool_ids: 1, status: 1, start_at: 1, end_at: 1 }` |
| `shops` | `Shop` | Shop catalog, reservation rules, communication channels, and resource integrations. | Unique case-insensitive `{ name: 1 }` with `en` strength-2 collation, partial when `name` is a string |
| `slack_users` | `SlackUser` | Current and historical mappings between members and Slack identities. | Unique `{ member_id: 1 }`, partial for object IDs with `invalidated_at: nil`; unique `{ slack_email: 1 }`, partial for strings with `invalidated_at: nil`; unique `{ slack_id: 1 }`, partial when `slack_id` is a string |
| `system_configs` | `SystemConfig` | Runtime feature flags, settings, and tracked job-run results. | Unique `{ key: 1 }` |
| `tool_checkout_requests` | `ToolCheckoutRequest` | Member requests for a Safety Checkout and their open/closed lifecycle. | None |
| `tool_checkouts` | `ToolCheckout` | Granted or revoked member Safety Checkouts for tools. | None |
| `tools` | `Tool` | Tool catalog, shop ownership, Safety Checkout prerequisites, and reservation rules. | Unique case-insensitive `{ name: 1 }` with `en` strength-2 collation, partial when `name` is a string |
| `volunteer_credits` | `VolunteerCredit` | Volunteer credit awards, approvals, discounts, and reversals. | `{ member_id: 1 }`; `{ status: 1 }`; `{ created_at: 1 }` |
| `volunteer_events` | `VolunteerEvent` | Volunteer events, attendees, eligibility prerequisites, and open/closed state. | `{ status: 1 }`; unique `{ event_number: 1 }`; `{ shop_id: 1 }` |
| `volunteer_tasks` | `VolunteerTask` | Volunteer bounties/tasks, claims, verification, recurrence, and credit values. | `{ status: 1 }`; `{ claimed_by_id: 1 }`; `{ parent_task_id: 1 }`; `{ shop_id: 1 }`; unique `{ task_number: 1 }` |

`EarnedMembership::ReportRequirement` is not listed as a collection because it
is embedded inside `earned_membership__report` documents.

## Keeping indexes in sync

The table describes the indexes expected from model declarations, not a live
database inspection. After changing an index declaration, update this file and
use the repository's Mongoid index deployment process for each environment.
