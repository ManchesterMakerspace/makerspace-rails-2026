# Member Statuses

`Member#status` is a case-sensitive string. The supported values are defined by
the validation in `app/models/member.rb`.

| Value | Meaning |
| --- | --- |
| `activeMember` | A fully activated member. This is the normal status after a card has been issued. |
| `pending` | A member who completed signup but has not yet been fully activated. Creating their card changes this status to `activeMember`. |
| `nonMember` | An account retained in the portal without active member privileges, such as someone who registered and never joined. A processed membership payment changes it to `activeMember` (see below). |
| `revoked` | Membership access has been revoked. Existing revocation workflows handle related deprovisioning and reservation cancellation. |
| `inactive` | An inactive account without active member privileges, such as a former member who left. A processed membership payment changes it to `activeMember` (see below). |
| `suspended` | A recognized suspended account state. It is not treated as an active membership status unless a feature explicitly defines otherwise. |

## Active membership checks

`Member#active_membership_status?` treats `activeMember` and `pending` as active
membership statuses. General membership checks should use this method instead
of comparing `status` directly.

`Member#active_unexpired?` additionally requires `expirationTime` to be present
and in the future. Expiration is therefore independent of `status`:
`activeMember` and `pending` records may still be expired.

`Member#fully_active_unexpired?` accepts only an unexpired `activeMember`. Use it
only where full activation, rather than general membership eligibility, is
required.

## Pending-member exceptions

Reservations and member-initiated Safety Checkout requests apply narrower
rules to pending members:

- A pending member may reserve only tools with `allow_pending: true`; pending
  onboarding access does not require `expirationTime` to be set.
- Pending members cannot create shop-wide reservations.
- A pending member may request a Safety Checkout only for a tool with
  `allow_pending: true`.
- Staff may directly issue any Safety Checkout to a pending member. The staff
  UI warns that the selected member is still pending but does not block the
  checkout.
- Issuing a card promotes the member from `pending` to `activeMember`.

When missing from a legacy Tool document, `allow_pending` is treated as
`false`.

## Related states

`expired` is not a supported `Member#status` value. It is a derived condition
based on `expirationTime`.

Card validity and reservation status are separate state machines. Values such
as card `lost`/`stolen` and reservation `approved`/`denied` must not be stored
in `Member#status`.

## Appendix: ways an existing member's status can change

This inventory covers application code that writes the `status` field on an
already-persisted `Member`. It deliberately excludes spec code and paths that
only choose the initial status of a new record (public registration, Firebase
first login, and admin member creation).

### API endpoints

| Entry point | Who/when | Possible transition |
| --- | --- | --- |
| `PATCH /api/admin/members/:id` or `PUT /api/admin/members/:id` (`Admin::MembersController#update`) | An authenticated admin or board member can include `status` in the request. The controller passes it to `Member#update!`, so the model's inclusion validation applies. Revocation and suspension also trigger their respective cleanup/session-invalidating behavior. | The current value to any supported value supplied by the caller. |
| `POST /api/admin/cards` (`Admin::CardsController#create`) | Creating a card runs the `Card#activate_pending_member` `after_create` callback. The callback does nothing unless the associated existing member is pending. | `pending` to `activeMember`. |

The card transition belongs to the model callback, not only to the HTTP
controller: creating a `Card` by any other application path that runs create
callbacks produces the same transition. Updating an existing card does not.

The authenticated `PATCH /api/members/:id` and `PUT /api/members/:id`
member-profile endpoints are **not** status-changing paths: their permitted
fields do not include `status`.

### Webhook callbacks

No webhook callback writes `Member#status` itself, but one reaches it indirectly:
when the PayPal IPN (`POST /ipnlistener`) or Braintree webhook
(`POST /billing/braintree_listener`) processes a membership payment, the invoice
is executed, and executing a membership invoice calls
`Member#reactivate_for_payment!` (see the next section). Mailtrap and Slack
callbacks do not write this field.

### Membership payments (invoice processing)

`Invoice#execute_invoice_operation` runs when a membership payment is processed,
and again for held payments when a member's first card is issued. For an invoice
with `resource_class: "member"` it first calls `Member#reactivate_for_payment!`:

| Current status | After a processed membership payment |
| --- | --- |
| `inactive` or `nonMember` | `activeMember`. This happens whether the payment is applied immediately or held because the member has no fob yet. |
| `revoked` or `suspended` | Unchanged. Those are deliberate staff decisions, so a payment never lifts them. |
| `activeMember` or `pending` | Unchanged. |

The write is atomic (no validations or callbacks), mirroring
`Card#activate_pending_member`. A member with a fob gets provisioning and the
Slack checkout canvas through the renewal that follows; a member with no fob has
them queued by the method itself. Each change writes a
`member_reactivated_by_payment` audit entry (no Slack post). Refunded invoices
are skipped when held payments are applied at the first fob.

### Jobs, tasks, model callbacks, and direct writes

- No scheduled job or Rake task changes an existing member's status.
  Expiration also never causes an automatic status transition.
- The status-writing paths in the model layer are `Card#activate_pending_member`
  and `Member#reactivate_for_payment!`, both described above.
- As with any persisted model field, maintenance code or a Rails console can
  change the value directly (for example, `member.update!(status: ...)` or
  assignment followed by `save!`). These validated writes accept only the
  supported values. Mongoid atomic/raw-database writes can bypass normal model
  validation and should be treated as an exceptional data-repair mechanism,
  not an application workflow.
