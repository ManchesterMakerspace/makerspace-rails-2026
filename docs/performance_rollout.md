# Performance configuration and rollout

This document covers the tunable settings, feature flags, deployment
prerequisites, rollout sequence, verification, and rollback procedures for the
Redis cache, Sidekiq workers, MongoDB aggregation pipelines, and reduced-memory
web configuration.

## Boolean flag rules

Environment flags are enabled only by the exact lowercase string `true`.
Values such as `1`, `TRUE`, `yes`, an empty value, or an absent variable are
treated as disabled.

Production defaults to the legacy or uncached path until each flag is enabled.
Development and test always use `MongoCache` and the new aggregation paths so
that normal development and CI exercise the code intended for rollout.

Changing an environment flag normally restarts application processes on
platforms such as Heroku. If the hosting platform does not restart processes
automatically, restart both web and worker processes after changing process
configuration.

## Rollout flag reference

| Flag | Production default | Scope | Enabled behavior | Disabled/rollback behavior |
| --- | --- | --- | --- | --- |
| `MONGO_CACHE_ENABLED` | Disabled | Mongo-backed reference and analytics caches | Reads and populates materialized `Rails.cache` entries in Redis. Model writes advance dependency versions. | Bypasses cache reads and population and queries MongoDB. Existing cache keys are harmless and expire normally. |
| `MONGO_AGGREGATION_ACTIVE_MEMBERS_ENABLED` | Disabled | `GET /api/admin/analytics/active_members` | Uses one `$facet` aggregation to load the member range and projected active-member data. The completed result can be cached when `MONGO_CACHE_ENABLED=true`. | Uses the legacy month-by-month implementation. |
| `MONGO_AGGREGATION_SPACE_USAGE_ENABLED` | Disabled | `GET /api/admin/space_usage` | Normalizes second/millisecond checkin timestamps, joins cards, and groups distinct member/date pairs in MongoDB. | Uses the legacy Ruby/Mongoid implementation. |

Aggregation flags are independent. Enabling the active-member pipeline does not
enable space usage or Redis caching. New endpoint flags follow this naming
convention:

```text
MONGO_AGGREGATION_<UPPERCASE_ENDPOINT_NAME>_ENABLED=true
```

Do not create a flag from the convention alone. A flag is supported only after
the corresponding endpoint calls `AggregationRollout.enabled?`.

Space-usage results are deliberately not cached because the `checkins`
collection has external writers. The eight-hour Mongo cache is also never
applied to `checkins` or `rejections`.

## Runtime tunables

### Member Portal setting

| Setting | Location | Default | Valid values | Application behavior |
| --- | --- | --- | --- | --- |
| Mongo Cache TTL | Admin → Member Portal Settings → Security | 8 hours | Whole number from 1 through 24 | Controls the lifetime passed to new `MongoCache` entries. Saving the setting immediately clears the Mongo-cache namespace so the new lifetime applies to subsequent reads. Model writes still invalidate affected entries before the TTL expires. |

The API/SystemConfig key is `mongo_cache_ttl_hours`. It is returned as
`security.mongo_cache_ttl_hours` by `GET /api/admin/system_configs` and accepted
by `PUT /api/admin/system_configs/update_setting`.

This TTL does not change:

- the short Braintree plan/discount cache;
- the Google/Firebase provider-specific cache lifetime;
- Sidekiq job retention;
- lock or invoice-lifecycle key lifetimes; or
- uncached `checkins` and `rejections` reads.

### Environment variables

| Variable | Default | Recommended production value | Notes |
| --- | --- | --- | --- |
| `REDIS_URL` | Local Redis outside production | Existing shared Redis URL | Used by `Rails.cache`, Sidekiq, locks, and operational notifications. Required in production. |
| `RAILS_MAX_THREADS` | `3` | `3` | Puma minimum and maximum threads. Increasing this raises web memory and requires a matching Mongo pool. |
| `MONGO_POOL_SIZE` | `5` | `5` | Maximum MongoDB connections per process in development and production. Keep it greater than or equal to Puma threads and worker concurrency, with operational headroom. |
| `ITEMS_PER_PAGE` | `50` | `50`, unless load testing supports another value | Pagination size read at process boot. It must be an integer greater than 1; invalid values fall back to 50. Larger pages increase serialization time and response memory. |
| `BRAINTREE_OPEN_TIMEOUT` | `5` seconds | `5` | Connection timeout for synchronous Braintree operations. |
| `BRAINTREE_READ_TIMEOUT` | `20` seconds | `20` | Read timeout for synchronous Braintree operations. Keep bounded because payment endpoints wait for the provider result. |

`RAILS_MAX_THREADS`, `MONGO_POOL_SIZE`, and `ITEMS_PER_PAGE` are read at process
boot and require a process restart to change.

### Sidekiq settings

Sidekiq settings live in `config/sidekiq.yml` rather than environment variables:

| Setting | Current value | Operational reason |
| --- | --- | --- |
| Concurrency | `2` | Limits worker RSS and concurrent integration calls. |
| Shutdown timeout | `25` seconds | Allows in-flight jobs a bounded period to finish during shutdown. |
| Queue order | `critical`, `mailers`, `default`, `integrations`, `slack` | Strict priority keeps revocation/cache safety and mail ahead of lower-priority integrations and notifications. |

If concurrency is changed, keep the Mongo pool larger than the new concurrency
and re-measure worker RSS, Redis usage, queue latency, and external-provider rate
limits. Memory-heavy document and backup jobs retain their single-execution
lock even when general concurrency is increased.

## Fixed Redis safety limits

The following values are safeguards, not runtime tunables:

- Rails cache namespace: `makerspace:cache:v1`
- default cache-store expiry: 8 hours
- compression threshold: 1 KB
- cache population high-water mark: 18 MB total Redis usage
- cache trim target: 16 MB total Redis usage
- reserved headroom target: at least 7 MB of the shared 25 MB instance

At or above 18 MB, the application bypasses new Mongo-cache population and
enqueues a trim. Trimming uses `SCAN`/`UNLINK` and selects only Mongo-cache keys;
it never trims Sidekiq queues, locks, invoice lifecycle data, or notification
keys.

Keep Redis `maxmemory-policy` set to `noeviction`. Cache failures are fail-open:
the request queries MongoDB, logs a warning, and reports the cache exception to
Honeybadger.

## Deployment prerequisites

Use these process commands:

```text
web:     bundle exec puma -C config/puma.rb
worker:  bundle exec sidekiq -C config/sidekiq.yml
release: bundle exec rake performance:prepare
```

Before enabling any flag:

1. Verify MongoDB and Redis backups and rollback procedures.
2. Verify Redis is configured with `noeviction`.
3. Run `bundle exec rake performance:prepare`. This installs Mongoid and
   external checkin/rejection indexes and safely replaces the legacy
   `invoice_options.plan_id_1` sparse index.
4. Confirm index builds completed without collection scans on hot selectors.
5. Start the Sidekiq worker and confirm all five queues are visible.
6. Confirm the production Redis server version. Sidekiq is pinned to 7.3 until
   Redis 7 or newer is verified; evaluate Sidekiq 8 only after that check.
7. Record baseline cold/warm latency, Mongo command count, Redis memory, queue
   latency, and web/worker RSS.

## Staged rollout

### Stage 1: infrastructure and asynchronous work

Deploy indexes, jobs, invalidation hooks, and the worker with all performance
flags absent.

Verify:

- web requests enqueue integrations without calling Slack, Google, SMTP, PDF,
  or nonessential Braintree operations inline;
- critical and mailer jobs are processed before lower-priority queues;
- retries and final errors appear in logs/Honeybadger; and
- Redis remains comfortably below 18 MB.

Rollback: restore the previous web release if job enqueueing changes request
behavior. Keep the worker running long enough to drain already accepted jobs
unless the jobs themselves are the rollback reason.

### Stage 2: Mongo reference caches

Set:

```text
MONGO_CACHE_ENABLED=true
```

Start with the default eight-hour TTL. Verify warm shop, tool, settings,
reservation-catalog, rental-type, invoice-option, permission, and privileged
member responses perform no MongoDB reads. Exercise create, update, atomic
update, and delete paths and confirm affected responses change immediately.

Watch Redis `used_memory`, cache hit/miss instrumentation, Mongo command count,
and Sidekiq queue latency. Do not continue if steady-state usage approaches
18 MB or trim jobs run continuously.

Rollback: remove or set `MONGO_CACHE_ENABLED=false`. Requests immediately
bypass the cache; no cache flush is required.

### Stage 3: active-member aggregation

Set:

```text
MONGO_AGGREGATION_ACTIVE_MEMBERS_ENABLED=true
```

Compare the active-member response against the legacy response for:

- an explicit year;
- the full available range;
- members with missing start or expiration values; and
- boundary dates at month end.

Verify one aggregation is issued and that warm requests use Redis when the
cache flag is also enabled. Monitor response p50/p95, Mongo execution time, and
cache entry size.

Rollback: remove or set
`MONGO_AGGREGATION_ACTIVE_MEMBERS_ENABLED=false`. This switches only this
endpoint back to the legacy implementation.

### Stage 4: space-usage aggregation

Set:

```text
MONGO_AGGREGATION_SPACE_USAGE_ENABLED=true
```

Compare daily and monthly output across the available date range. Include
checkins stored in seconds and milliseconds, unknown card UIDs, and multiple
checkins by the same member on the same day.

Verify each request observes newly inserted checkins without waiting for a
cache TTL. Monitor Mongo aggregation time and response p50/p95; there should be
no Mongo-cache entry for the result.

Rollback: remove or set `MONGO_AGGREGATION_SPACE_USAGE_ENABLED=false`. This
switches only space usage back to the legacy implementation.

### Stage 5: process-memory comparison

After traffic has stabilized, compare the new one-process/three-thread Puma
configuration and Sidekiq worker against the pre-rollout baseline. Measure boot
RSS, steady-state RSS, queue latency, throughput, and request p95 before
considering any thread, pool, or concurrency change.

## Acceptance and monitoring

For every stage, record:

- cold and warm p50/p95 response latency;
- MongoDB command/aggregation count and execution time;
- cache hit rate and serialized entry size;
- Redis `used_memory` and trim-job frequency;
- Sidekiq queue depth, oldest-job latency, retries, and dead jobs; and
- web and worker RSS.

Target steady-state Redis usage below 18 MB. Keep at least 7 MB available for
queue bursts and operational data. Enable only one rollout flag between
observation windows so regressions can be attributed and rolled back
independently.
