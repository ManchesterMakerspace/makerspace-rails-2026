# Reservation read performance

Reservation modal builds and reservation evaluations use a short-lived
`ReservationReadContext`. It shares candidate tools, current checkout records,
prerequisite names and invoice options within one operation. It is not stored in
Redis, a session, or Slack private metadata. Create/update evaluation constructs
fresh context inside the existing reservation locks, after the member reload.
Today-only eligibility and checks through each candidate end reuse one checkout
read. End-specific eligibility is evaluated per end time, rather than reusing a
cached today-only result; names and candidate tools remain cached within the build.

Slack selected-tool validation and rendering share the same candidate list.
Fee snapshots accept the already-loaded resources and batch distinct enabled fee
options, while retaining historical snapshots and legacy fee-free rules. Policy
and authorization decisions remain in the existing Ruby services.

## Timing events

The Rails log receives JSON records with `event: "reservation_timing"`, a fixed
`operation`, `resource_count`, `outcome` (`success`, `rejected`, or `error`), and
monotonic `elapsed_ms`. No request payloads or identifiers are included.

Operations:

- `slack_modal_build`: building/rendering a view; during updates this can reuse
  data already fetched by validation.
- `slack_modal_update`: the update handler, including validation and Slack I/O.
- `slack_views_open` and `slack_views_update`: Slack API calls only.
- `reservation_preview`: shared portal preview logic, including response assembly.
- `reservation_evaluate`: the shared evaluator used by previews and locked writes.

Nested timings overlap and must not be summed. A successful evaluation means
validation passed, not that persistence or a later Slack API call succeeded.
These timings do not include HTTP queueing, authentication, or every controller
lookup. Use end-to-end request latency to assess Slack's three-second deadline.

## Reproducing the benchmark

Provide an authorized test database through the existing `MLAB_URI` environment
variable, then run:

```sh
bundle exec rspec spec/benchmarks/reservation_reads_spec.rb --tag benchmark --format progress
```

The `benchmark` tag is excluded by default in `spec_helper`, including when CI
discovers the file through `parallel_rspec spec/ -n 4`. Naming the file alone
does not opt in; the explicit `--tag benchmark` flag is required. The ordinary
query-count regression specs remain part of the default suite.

This uses the normal test suite's database safety check and DatabaseCleaner:
the test database is cleared. Do not run concurrently with other tests against
the same database. Do not commit connection credentials.

The benchmark uses 1, 25, and 100 selected tools with a shared prerequisite and
fee option, a current ordinary member, and active checkouts. Each operation has
one warm-up followed by ten measurements. Fixture creation is outside the timed
region. Mongo driver monitoring counts actual read commands, including `getMore`,
and records database command duration without retaining command payloads.

`RESERVATION_BENCHMARK` lines report read counts, collection breakdowns, elapsed
and database p50/p95 milliseconds. Percentiles use nearest rank; with ten samples
p95 is the maximum. Slack API calls are mocked; the portal measurement invokes
the shared preview service, excluding HTTP/authentication/serialization overhead.
The dataset contains no existing reservations or blackouts. These are comparative
microbenchmarks, not production latency guarantees.

## Measured comparison (2026-09-17)

Windows, Ruby 3.4, the supplied Atlas `devtest` database; identical fixture sizes
and ten measurements per operation before and after the change (baseline commit
`6bd423bf`). No index changes
were made between runs. Both runs reported the existing missing required tools
unique index in this test database. Network conditions varied between sequential
runs, so use command-count reductions alongside elapsed-time comparisons.

All timing columns are milliseconds, shown as **before → after**.

| Operation | Tools | Read commands | Total p50 | Total p95 | Database p50 | Database p95 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Modal build | 1 | 4 → 4 | 172.1 → 126.4 | 182.9 → 142.2 | 156.0 → 119.6 | 167.7 → 136.0 |
| Modal update | 1 | 8 → 6 | 335.2 → 189.1 | 379.6 → 206.2 | 297.0 → 180.5 | 324.8 → 196.7 |
| Portal preview service | 1 | 13 → 11 | 462.1 → 360.0 | 511.5 → 394.8 | 420.6 → 342.5 | 452.4 → 379.0 |
| Modal build | 25 | 28 → 4 | 1022.8 → 143.0 | 1145.7 → 159.1 | 917.5 → 133.5 | 1016.5 → 148.4 |
| Modal update | 25 | 32 → 6 | 1297.0 → 217.7 | 1378.3 → 239.0 | 1138.9 → 204.3 | 1243.0 → 224.3 |
| Portal preview service | 25 | 61 → 35 | 2410.6 → 1154.1 | 2679.2 → 1200.3 | 2127.4 → 1095.1 | 2327.0 → 1137.7 |
| Modal build | 100 | 105 → 5 | 3853.1 → 218.8 | 4416.6 → 221.1 | 3473.6 → 182.5 | 3932.6 → 191.0 |
| Modal update | 100 | 110 → 7 | 4187.0 → 282.2 | 4541.0 → 295.3 | 3750.6 → 249.6 | 3999.5 → 266.2 |
| Portal preview service | 100 | 212 → 111 | 8240.8 → 3994.7 | 9011.1 → 4253.8 | 7354.6 → 3646.6 | 7963.7 → 3855.1 |

The 100-tool after-change modal reads include one checkout cursor `getMore`.
Each modal build/update now issues one candidate query, one active-checkout query,
one supplemental prerequisite-name query and one fee-option query. Updates also
fetch the shop and member. Portal evaluation reuses its selected tools, needs no
supplemental names for this eligible fixture, and issues one fee-option query.
Its remaining 103 reservation-history/conflict reads at 100 tools explain why
the portal preview still exceeds three seconds in this benchmark. Slack network
latency was not measured; API calls were mocked in both runs.

Validation covered 194 distinct database-backed examples, including the three
benchmark scenarios, plus 15 standalone fee-pricing examples. All passed after
updating the existing interaction mock to accept the request-local context.
Coverage includes query-count bounds, pending/expired/board eligibility, invalid
selections, historical and legacy fees, and checkout revocation/price changes
between preview and lock acquisition.

## Remaining work

The shared evaluator still reads reservation session history per resource.
This change does not redesign history/conflict queries or asynchronous Slack
acknowledgement. Those costs remain visible separately from catalog/fee reads.
No public API contract, collection, environment variable, or recurring job changed.

## Eventbrite and announcement read benchmark

The Eventbrite history reader batches parent/ticket metadata and aggregates order
member IDs; link filters use correlated organization/order existence joins.
Shared event name/start/timezone, ticket names and public signup choices use a
five-minute display cache with generation-fenced publication and MongoDB fallback.
Signup choices also expire at Eastern midnight; mutation validation/member links
remain live. Announcements use projected live reads scoped by channel bindings,
and canvas rendering batches names/tools. Full snapshots, availability, payment
reconciliation and delivery state are not cached.

Run explicitly against disposable MongoDB/Redis using the normal test safety
hooks (DatabaseCleaner deletes the selected test database's records):

```sh
bundle exec rspec spec/benchmarks/eventbrite_announcer_reads_spec.rb spec/benchmarks/eventbrite_reservation_indexes_spec.rb --tag benchmark --format progress
```

The first file measures 1/50-row history and canvas reads and 1/4-channel
reconciliation with ten bookings per channel. History invokes the controller
action with rendering stubbed: authentication, HTTP and JSON serialization are
excluded. Canvas markdown rendering is real; Slack network calls are mocked.
The announcer canvas callback renders the real agenda but replaces external
canvas I/O. Fixture creation is outside measurements; message-update runs clear
the fingerprint with a setup write included in elapsed time. Both unchanged and
message-update runs refresh canvases. Five warm
samples report median and nearest-rank p95 (the maximum). Cold history has one
sample, followed by five cache-hit samples. The monitor counts actual read
commands, including `getMore`, and BSON-encodes reply sizes without retaining
payloads. Reported bytes include command/cursor envelopes and precede compression;
they are comparative database reply sizes, not exact network usage.

### Measured comparison (2026-11-20)

Windows Ruby 3.4, MongoDB 8.2.6 single-node replica set and an isolated WSL Redis.
Baseline was commit `394ae35d` with its existing indexes installed; after-change
data used the same fixture sizes plus the two additive indexes. Runs were
sequential with no other test workload. Local MongoDB version differs from CI's
MongoDB 7.0; these measurements do not substitute for that deployment's tests.

Warm timings below are milliseconds, **before → after**:

The unchanged-announcer rows record the earlier fingerprint fast path, which
could skip live-agenda changes. They are historical; current unchanged-message
costs appear in the live-agenda freshness measurements below.

| Operation | Rows/channels | Read commands | BSON reply bytes | Total p50 | Total p95 |
| --- | ---: | ---: | ---: | ---: | ---: |
| Order history, warm metadata | 50 rows | 102 → 3 | 346,470 → 11,698 | 1,613.21 → 63.07 | 1,624.91 → 77.17 |
| Attendee history, warm metadata | 50 rows | 102 → 2 | 362,316 → 10,824 | 1,612.97 → 75.25 | 1,630.21 → 102.11 |
| Canvas markdown | 50 rows | 102 → 4 | 131,195 → 14,008 | 1,628.52 → 82.56 | 1,645.64 → 92.66 |
| Announcer, unchanged | 1 channel | 13 → 10 | 17,040 → 8,710 | 235.99 → 188.42 | 238.04 → 201.19 |
| Announcer, canvas refresh | 1 channel | 40 → 18 | 51,538 → 16,210 | 773.92 → 421.21 | 784.72 → 441.33 |
| Announcer, unchanged | 4 channels | 31 → 25 | 127,389 → 35,299 | 644.30 → 539.15 | 652.95 → 585.39 |
| Announcer, canvas refresh | 4 channels | 139 → 57 | 332,845 → 69,223 | 2,716.11 → 1,404.13 | 2,810.34 → 1,436.73 |

Both 50-row cold history pages used four MongoDB reads after the change (order
96.66 ms; attendee 113.54 ms), versus 102 before. The one-row canvas stayed at
four reads. Each warm metadata category uses one atomic Redis read, including its
generation check. One-row warm order/attendee p50 remained roughly unchanged
(63.50/62.79 ms before; 62.79/63.27 ms after). Cold fills still pay cache-publication
overhead. Benefits depend on data size, repeated metadata and actual Redis/MongoDB
latency; the table is not a production latency guarantee.

### Live-agenda freshness (2026-11-21)

Announcement reconciliation now refreshes linked canvases and repeats the live
snapshot before comparing the final message fingerprint. Overnight carryover
edits and cancellations therefore refresh the agenda even when today's starting
rows are unchanged, including shops with only tool-users destinations. Successful
unchanged-message runs also clear receipt retry state. Only the Slack message
write is skipped; canvas rendering and I/O still run under the channel lease.

The two announcer benchmark examples were rerun on the same local service versions
and fixture sizes, with five measurements per path. Current costs are:

| Operation | Channels | Read commands | Returned documents | BSON reply bytes | Total p50 (ms) | Total p95 (ms) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Announcer, unchanged message | 1 | 18 | 52 | 16,279 | 426.55 | 502.71 |
| Announcer, message update | 1 | 18 | 52 | 16,210 | 437.60 | 473.70 |
| Announcer, unchanged message | 4 | 57 | 256 | 69,499 | 1,421.01 | 1,470.29 |
| Announcer, message update | 4 | 57 | 256 | 69,223 | 1,438.52 | 1,473.54 |

Unchanged-message reads rise from the historical 10/25 to 18/57 for one/four
channels because the agenda and post-I/O snapshot can no longer be skipped.
Changed-message read counts remain 18/57. Slack network calls are mocked, so
these timings exclude real canvas latency and rate limits.

### Live-agenda freshness (2026-11-21)

Announcement reconciliation now refreshes linked canvases and repeats the live
snapshot before comparing the final message fingerprint. Overnight carryover
edits and cancellations therefore refresh the agenda even when today's starting
rows are unchanged, including shops with only tool-users destinations. Successful
unchanged-message runs also clear receipt retry state. Only the Slack message
write is skipped; canvas rendering and I/O still run under the channel lease.

The two announcer benchmark examples were rerun on the same local service versions
and fixture sizes, with five measurements per path. Current costs are:

| Operation | Channels | Read commands | Returned documents | BSON reply bytes | Total p50 (ms) | Total p95 (ms) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Announcer, unchanged message | 1 | 18 | 52 | 16,279 | 426.55 | 502.71 |
| Announcer, message update | 1 | 18 | 52 | 16,210 | 437.60 | 473.70 |
| Announcer, unchanged message | 4 | 57 | 256 | 69,499 | 1,421.01 | 1,470.29 |
| Announcer, message update | 4 | 57 | 256 | 69,223 | 1,438.52 | 1,473.54 |

Unchanged-message reads rise from the historical 10/25 to 18/57 for one/four
channels because the agenda and post-I/O snapshot can no longer be skipped.
Changed-message read counts remain 18/57. Slack network calls are mocked, so
these timings exclude real canvas latency and rate limits.

### Index probes

The second benchmark uses `explain("executionStats")` on disposable fixtures and
restores the added attendee index after comparing existing indexes. A global
reservation lookup with 10,000 historical approved bookings plus ten current
bookings examined **10,010 → 10** documents using
`status_1_end_at_1_start_at_1`; the final result still sorts by start time/ID.
For 100 orders and 5,000 attendees, the new correlated-lookup index reduced
foreign keys examined **199 → 100**, with no foreign collection scans. Both
probes assert use of the intended index. Planner choices and savings depend on
data distributions; do not add general history sort index permutations without
measuring representative filters.

Apply the indexes with `bundle exec rake data:ensure_unique_indexes` before
deploying optimized readers. No environment variables, public schemas, client
publication, React changes or wiki flow changes are needed for this optimization.

### Validation

Before the live-agenda freshness correction, the four-worker RSpec run completed
4,504 examples with zero failures and
three existing pending examples: the optional `SLACK_PROFILE_STATUS` and
`SLACK_PROFILE_FULLNAME` fixtures were absent, and the secondary-household
password-reset mail example remains disabled with `xit`. Strict transaction mode
was enabled; no transaction examples were skipped, and the independent probe
verified real commit and rollback. The opt-in read/index benchmarks passed all
eight examples. A separate 42-example follow-up passed the current versions of
three test files edited while the full run was active. These results cover the
combined Rails workspace, including the accompanying volunteer weekday changes.
### Canvas refresh validation

The live-agenda correction passed 136 related service, canvas, job and model
refresh examples, plus both opt-in announcer benchmarks, with zero failures and
no pending examples. The four new regressions first failed against the old fast
path and now cover carryover edits/cancellations on a tool-users-only shop,
refresh failure/retry cleanup, and availability changes during canvas I/O.
Strict transaction mode and the independent commit/rollback probe passed. The
full four-worker suite was not repeated for this narrow service correction.
