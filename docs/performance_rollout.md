# Performance rollout

The cache and aggregation paths are production feature-gated so indexes and
workers can be deployed before traffic moves to them.

## Required process configuration

- Web: `bundle exec puma -C config/puma.rb`
- Worker: `bundle exec sidekiq -C config/sidekiq.yml`
- Release: `bundle exec rake performance:prepare`
- Set `RAILS_MAX_THREADS=3`, `MONGO_POOL_SIZE=5`, and use the existing
  `REDIS_URL`.
- Keep Redis `maxmemory-policy` set to `noeviction`.

Sidekiq is pinned to 7.3 until the production Redis server is verified as
Redis 7 or newer. After that verification, Sidekiq 8 can be evaluated.

## Feature flags

1. Deploy indexes and start the worker with the flags absent.
2. Set `MONGO_CACHE_ENABLED=true` to enable Mongo-backed reference caches.
3. Set `MONGO_AGGREGATION_ACTIVE_MEMBERS_ENABLED=true`.
4. Set `MONGO_AGGREGATION_SPACE_USAGE_ENABLED=true`.

The app stops populating Mongo caches at 18 MB total Redis usage and schedules
a `SCAN`-based trim toward 16 MB. Queue, lock, invoice lifecycle, and
notification keys are never selected by the cache trim.

## Verification

Track warm/cold p50 and p95, Mongo command count, cache hit ratio, Redis
`used_memory`, Sidekiq queue latency, and web/worker RSS. Keep steady-state
Redis use below 18 MB and validate response contracts before enabling each
aggregation flag.
