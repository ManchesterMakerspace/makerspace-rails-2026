# ESP32 reader integration (pending deployment)

The new sibling makerspace-reader-esp32 project implements Waveshare ESP32-S3-ETH / Elechouse PN7160 readers, with PN532 fallback at 7-bit I2C address 0x24 when PN7160 is absent. PN7160 discovery uses its active-HIGH IRQ; PN532 uses active-LOW IRQ. Both require the same protected-sector authentication. Its PLAN.md, README.md, docs/PROTOCOL.md and docs/COMMISSIONING.md are the firmware references. The sibling ts-data-api service implements /reader/v1 endpoints; see its READER_API.md.

This is a companion-service integration, not a Rails controller or React workflow change. No Rails routes, generated Swagger/client contracts, billing behavior, member statuses, email triggers or Rails schedules change here.

## Authorization and assignment

Rails remains authoritative for cards, current member status/expiration, tools, shops and tool checkouts. The reader requires activeMember plus unexpired card and member permissions. Tool readers also require a non-revoked, non-superseded, unexpired checkout; expires_on uses end of date in America/New_York. Tool/shop unavailability removes grants.

Assign a UID through the existing transactional card workflow first. A supervised enrollment station provisions per-card Classic keys and a protected random credential. Unknown cards remain rejection candidates and are not automatically assigned. The API binds credentials to the card ObjectId, UID and member; release/reassignment invalidates the old binding. It writes an internal readerEnrollmentFence on cards inside enrollment transactions to conflict with concurrent card mutation. This does not invoke Rails callbacks or change status.

Classic remains susceptible to cryptographic cloning attacks. The new check is stronger than UID-only acceptance but is not equivalent to a modern secure NFC protocol.

## Records and operational ownership

ts-data-api owns nfc_readers and nfc_card_credentials and writes existing checkins/rejections collections using the established scan fields plus deviceId, reason and timeQuality. It reads Rails-owned collections and does not modify member eligibility or grant checkouts. Server credentials are encrypted at rest; device credentials are restricted to reader routes and do not authorize the generic data API.

Firmware caches at most 300 cards and 150 grants. FirstScan is station-local and never written into cards. During network outages, cached permissions remain valid until expiry; revocations cannot reach an offline station. Event replay is idempotent in MongoDB and at least once in MQTT. MQTT consumers must deduplicate on _id.

## Release requirements

Deploy ts-data-api/indexes and the mTLS gateway/broker policy first. Provision and bench-test hardware, then deploy a core built for secure boot, flash/NVS encryption and signed OTA. The stock Arduino core is suitable for bench compilation, not production admission.

The firmware project contains docs/wiki-reader-rollout.patch for a new admin reader page and existing member troubleshooting page. It is held until commissioning; nothing was published to the live wiki. Fetch/reconcile WikiPages and submit a PR at release.

No React rebuild or generated Rails client publication is required. API tests use a disposable MongoDB replica set. Rails application tests and Swagger regeneration are not applicable to this documentation-only Rails change.
