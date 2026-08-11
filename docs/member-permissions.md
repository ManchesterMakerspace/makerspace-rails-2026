# MongoDB member permissions

This page is the canonical reference for the member-permission system. The
system has two similarly shaped Mongoid collections with different roles:

| Model | MongoDB collection | Schema and role |
| --- | --- | --- |
| `DefaultPermission` | `default_permissions` | A global template. It has `name: String` and `enabled: Boolean` (default `false`). |
| `Permission` | `permissions` | A member-specific authorization record. It has `name: String`, `enabled: Boolean` (default `false`), and a required `member` association. |

`Member#has_many :permissions` uses `dependent: :destroy`, so destroying a
member destroys that member's permission records. Neither permission model
enforces unique names or checks names against a fixed allowlist. Both validate
only that `name` is present. Consequently, duplicate or arbitrary names can be
stored, even though arbitrary names have no effect unless application code
consumes them.

## Creation, defaults, and updates

`Member#apply_default_permissions` runs in the member's `after_create`
callback. It takes the current `DefaultPermission.list_as_hash` snapshot and
passes it to `Member#update_permissions`. For every name/value pair,
`update_permissions` updates an already associated record with the same name,
or upserts a new member-specific `Permission`.

Defaults are copied, not dynamically inherited. Changing a
`DefaultPermission` affects members created afterward but does **not** update
existing member records automatically. Likewise, a default that is `true`
does not override a member's later per-member value.

`Admin::PermissionsController#update` calls `Member#update_permissions` and
writes a `permissions_updated` audit event containing before and after
snapshots. This update path never deletes records. Other than dependent
deletion when a member is destroyed, removals require direct model/database
maintenance. Normal revocation should retain the record and set `enabled` to
`false`.

## Reading permissions and API routes

`Member#get_permissions` returns every stored permission for that member as a
name-to-Boolean hash. `Member#is_allowed?` grants access only if a matching
member record exists and its `enabled` value is truthy. A missing record and a
disabled record both deny access.

The authenticated member endpoint exposes that hash:

* `GET /members/:member_id/permissions` — handled by
  `Members::PermissionsController#index`. It permits the member themself, an
  admin, a board member, or a resource manager; other callers are forbidden.

The admin endpoints are:

* `GET /admin/permissions` — handled by
  `Admin::PermissionsController#index`. It returns the distinct names actually
  found in the per-member `permissions` collection. Names present only in
  `default_permissions` do not appear.
* `PATCH /admin/permissions/:id` (also `PUT`) — updates the member identified by
  `:id` from the `member[permissions]` hash and records the audit event.

## Recognized names and current consumers

`DefaultPermission::WHITELISTS` is the application's current registry of
recognized names:

| Name | Current code consumer |
| --- | --- |
| `billing` | `BillingGate` passes the constant to `Member#is_allowed?`; this is member-level enforcement. |
| `earned_membership` | No direct member-level enforcement path currently consumes this constant. |
| `paypal_transfer` | The member-review rake task directly queries the matching globally enabled `DefaultPermission` before sending its PayPal report. It does not call `Member#is_allowed?`. |
| `ping_no_purchase` | The member-review rake task directly queries the matching globally enabled `DefaultPermission` before sending its no-purchase report. It does not call `Member#is_allowed?`. |

`custom_billing` appears in test seed data, but is not an application-defined
permission and has no production consumer currently.

## What `enabled` means

The model containing the field determines its meaning:

* On `DefaultPermission`, `enabled` is the value copied into a newly created
  member's permission. Global feature/report logic may also query the default
  record directly, as the member-review task does.
* On `Permission`, `enabled` determines whether that particular member passes
  `Member#is_allowed?` for the name.

Setting either field to `false` retains both the record and its name; it does
not remove anything. Because defaults are only copied at member creation, a
default value of `true` never supersedes a member's later per-member value.

## Adding a new permission name

1. Choose one canonical `snake_case` name and add it to
   `DefaultPermission::WHITELISTS`.
2. Add a `DefaultPermission` record through the project's deployment, seed, or
   migration mechanism. Choose its initial `enabled` value intentionally.
3. Reference the canonical constant from the controller, service, or task that
   enforces the feature. Use `Member#is_allowed?` for member-specific
   authorization.
4. Decide whether existing members need a `Permission` backfill. Updating or
   inserting a default alone does not propagate to them.
5. If the name must appear in `Admin::PermissionsController#index`, ensure at
   least one per-member record exists, or separately revise that endpoint to
   read from a canonical registry.
6. Update factories and specs to cover default copying, enabled, disabled,
   missing-record, update, and authorization behavior.

Merely inserting an arbitrary `name` passes current model validation, but does
not make the permission functional. Some controller, service, or task must
consume that name.

## Rails console examples

Inspect the global templates and a member's stored permissions:

```ruby
DefaultPermission.order_by(name: :asc).pluck(:name, :enabled)

member = Member.find("MEMBER_ID")
member.get_permissions
member.permissions.order_by(name: :asc).pluck(:name, :enabled)
```

Enable or revoke access through the normal update path (revocation disables
the record rather than deleting it):

```ruby
member.update_permissions(billing: true)
member.reload.is_allowed?(DefaultPermission::WHITELISTS[:billing]) # => truthy

member.update_permissions(billing: false)
member.reload.is_allowed?(DefaultPermission::WHITELISTS[:billing]) # => falsey
```

Inspect the distinct names stored on members (the source used by the admin
index):

```ruby
Permission.distinct(:name)
# Equivalent application helper:
Permission.list_permissions
```
