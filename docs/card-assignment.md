# Card assignment

`POST /api/admin/cards` requires an active, unexpired administrator or board
member for every assignment, including legacy reader imports. The optional
`source` field is audit-only; it cannot change authorization or identifier
validation. The existing NFC client sends `source: "nfc"`, recorded in the
persisted assignment audit message as `Card UID source: NFC scan (client-reported)`.
`import` records `Reader import (client-reported)`; missing or unknown values
record `Unspecified`. Only these fixed labels are logged, never arbitrary source
text. Source identifies the reported client workflow, not verified hardware.

New identifiers must be uppercase hexadecimal ASCII byte pairs, preserving
leading zeroes (for example, `001B1A4D2F`). Legacy identifiers are accepted only
when they exactly match a server-side `RejectionCard` with no holder and a
`timeOf` later than yesterday's start, matching the existing Import New Key
candidate window. Stale, claimed, and unobserved noncanonical identifiers return
422. No API route accepts an arbitrary noncanonical UID based on `source`.

Assignment, old-card invalidation, pending-member activation, rejection-card
claiming, and the finalized audit snapshot share one MongoDB transaction.
Invoice and provisioning effects run only after commit.

`GET /api/admin/cards/lookup?uid=...` accepts an exact UID already assigned to a
card, including noncanonical legacy identifiers. It performs no normalization or
case folding. Unknown canonical UIDs return 404; unknown noncanonical or nonstring
values return 422. Ambiguous duplicate records still return 409. The same active
admin/board policy applies. Legacy results include the card ID and version needed
to release an eligible assignment.

Release creates a `card_released` audit in the same transaction as deletion,
including the actor, former member when available, card ID, full pre-release
snapshot (including UID), and an empty post-release snapshot. The audit remains
after the card is deleted, including for orphaned lost cards. If audit storage
fails, release rolls back; if deletion fails, the audit also rolls back.

## Fob issuers (volunteers)

Open house volunteers can register a member's **first** key fob without being admin
or board. The ability is a safety checkout, not a permission: exactly one tool has
`grants_fob_issuance` set (admin/board only; `Tool` validation allows a single
flagged tool, and resource managers cannot set the flag). A member is a fob issuer
(`Member#fob_issuer?`) while they are fully active and unexpired and hold a current,
unexpired checkout on that tool. Its prerequisites (orientation, tour guide) are
ordinary tool prerequisites enforced by the normal checkout flow; revoking or letting
the checkout expire removes the ability at once.

`FobIssuanceController` (separate from `Admin::CardsController`, which stays admin
and board only) serves these routes, all returning 403 to anyone who is not a fob
issuer, including admins who are not also issuers:

| Route | Purpose |
| --- | --- |
| `GET /api/fob_issuance/members?search=` | Members matching name or email (at least 2 characters, 25 at most) who have no usable card (lost and stolen cards do not count), are not revoked, and are not the caller. Identity fields only: name, email, phone, address, status, expiration, contract on file. No billing, notes, or provisioning data. |
| `GET /api/fob_issuance/members/:id` | The same fields for one eligible member; 404 otherwise. |
| `GET /api/fob_issuance/cards/new` | The most recent unclaimed reader rejection UID, as for the admin form. |
| `POST /api/fob_issuance/cards` | `member_id`, `uid`, optional `source`. Same UID rules as the admin route. Calls `CardManagement.assign!` with `initial_only: true`, so the assignment fails with 409 inside the transaction if the member already has a usable card (a fob issuer can never replace or invalidate a fob). The caller cannot be the recipient. Activation of a pending member, invoice settlement, provisioning and the `card_assigned` audit (actor = the issuer) are the same as for staff. |

The member payload (`GET /api/members/:id` and the sign-in and session responses) carries
`isFobIssuer`, which tells the portal to show the Issue Fob screen.

After a successful issue, `FobIssuanceNotifier` sends the member a Slack direct
message (when their Slack account is linked) and posts to the members relations
channel. Failures there are logged and do not undo the card.


## Phone enrollment and reader fallback

Register/Replace Fob and volunteer Issue Fob share two paths. Chrome offers
**Continue in Android app** and **Use enrollment reader instead**. The handoff
contains only a member ID and workflow; the app restores its own login/TOTP session,
reloads the member and requires a fresh identity-verification confirmation.
Chrome Web NFC cannot program the protected Classic credential.

Native Android enrollment supports MIFARE Classic 1K/4K with 4-/7-byte UIDs on
phones exposing Android MifareClassic. Scan the UID, verify the member's ID, submit,
tap to check compatibility, then tap and hold to program. Remove and retap to verify.
Only the final Rails transaction assigns the card and invalidates the old fob.
Cancellation/tag loss leaves encrypted pending material for a same-card retry.
Unrelated nonblank sector data is never overwritten. A damaged trailer requires
operator recovery or a replacement card; never discard pending material to retry.

Reader fallback uses the existing assignment endpoints and either browser UID
scanning or front-door scan/Import New Key. Assignment immediately invalidates the
old usable fob and can activate a pending member, as before. The operator must then
present the assigned card to an enrollment-enabled reader. The UI says:

> Card UID assigned. To finish issuing or replacing this fob, present it to an enrollment-enabled reader. The fob is ready only after that reader completes enrollment.

The UI does not observe station completion. Arrange station access before replacing
a fob; ask an authorized operator if no enabled station is available. Reader begin
creates/reuses encrypted pending material in nfc_card_credentials; reader commit
activates it after readback. Native pending attempts block conflicting UID assignment.

Admin/board operators must be fully active and unexpired. Volunteers must retain
the fob-issuer checkout and may issue only to another non-revoked member without a
usable fob. Lost/stolen cards retain the existing first-fob eligibility semantics.
Native preparation/commit also require a signed contract and preparation requires
an explicit ID-verification attestation. Neither UID nor readback digest proves
identity or independently proves RF possession; programmers are authorized actors.

Native APIs, under both /api/admin/card_enrollments and
/api/fob_issuance/card_enrollments, are POST collection (memberId, uid, idVerified),
GET /:id (secret-free status), and POST /:id/commit (revision, digest). Preparation
returns id, uid, memberId, cardId, revision, state and transient material; status and
commit omit material. Inputs accept existing JSON key transformation. Responses
are direct hashes. Authentication, TOTP, CSRF and private/no-store remain enforced.
Conflicts return 409, invalid preparation 422, unavailable storage/key 503.

Deploy the same existing READER_KEY_ENCRYPTION_KEY into Rails, run
`bundle exec rake data:ensure_card_enrollment_indexes`, then deploy Rails before
web/native builds. Preserve the key and existing encrypted credentials. No automatic
card reset, migration, pending TTL or orphan cleanup occurs. Deploying code is not
physical acceptance: test actual phones, cards, tag loss and reader admission.


### Validation and release checklist

The implementation was checked with an isolated disposable MongoDB replica set,
including staged replacement, readback rejection, rollback on audit failure,
legacy-assignment conflicts, idempotent completion and volunteer revocation.
External notification dependencies are stubbed in request tests.
`ruby scripts/ci/verify-nfc-codec.rb` checks Ruby-to-Node and Node-to-Ruby AES-GCM
interoperability and the firmware metadata/digest format using an ephemeral test key.

Before release, provision the shared encryption key, create enrollment indexes,
deploy Rails then the web/Android app, and physically verify phone/card compatibility,
interrupted programming/recovery, Chrome-to-app login/TOTP, and ESP32 admission.
No production data changes, key rotation, app distribution, flashing or wiki
publication were performed. The operator text is held in
[the phone enrollment draft](wiki-phone-enrollment-draft.md).


Automated results: the assignment/enrollment run passed 35 examples. After adding
error/recipient cases, the enrollment plus legacy volunteer run passed 48 of 49;
the existing profile-flag example at `spec/requests/fob_issuance_spec.rb:184` failed
because its profile serializer needs a reachable Redis service. New enrollment
examples passed. The full Rails suite was not run. Re-run that legacy example with
Redis available before release. Swagger generation is a dry-run artifact step and
is not additional executed API coverage.
