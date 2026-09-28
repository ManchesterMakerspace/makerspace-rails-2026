# Tool group implementation validation

Validated on Windows on 2026-09-27, using the supplied `MLAB_URI` test replica
set (`dev_test_rspec`). The replica set advertises `mongo:27017`; a temporary,
process-local Ruby socket alias resolved that hostname to the supplied host.
No application database configuration or system DNS was changed.

- 297 distinct Rails examples passed across focused runs, using each example's
  latest result. The final group, concurrency, snapshot, Slack and calendar
  regression pass completed with 89 examples and zero failures.
- Covered group validation and shop/role boundaries, shared naming and tool
  reference guards, revision changes, internal/external prerequisites, open tools,
  partial and revoked checkouts, overlapping requests, transactional rollback,
  retry identity, notification failure, persistent approver grants, volunteering,
  shared credit/reversal, reservation expansion, outages, capacity, snapshots,
  legacy edits, calendar synchronization, and existing fee behavior.
- Concurrent individual/group approvals used independent MongoDB sessions and
  threads with a process-local implementation of the keyed lock contract.
  Redis operations and external Slack/calendar services were mocked; this does
  not constitute a live distributed-lock or external-service acceptance test.
- Ruby syntax passed for 59 changed Ruby files. `rswag:specs:swaggerize`
  regenerated `swagger/v1/swagger.json`; its 857 dry-run examples are schema
  generation, not additional executed API tests.
- React: all 62 Jest suites passed (354 tests). Relevant checkout/reservation
  tests were rerun after final UI changes. `npm run typecheck` passed using the
  repository's configured TypeScript command.
- The actual shared group form passed Chromium checks at 320, 600, 900 and
  1280 pixels: labeled inputs, disjoint selectors, default flags, no horizontal
  overflow and no browser JavaScript errors. Screenshots were visually reviewed.
  The fixture and check script are in the React repository under
  `tests/browser/tool-groups`; this is component browser coverage, not a full
  authenticated portal acceptance run.
- Production web and native web bundles built. Android debug compilation used
  the installed JDK/Android SDK and the configured production API origin.
  Existing webpack warnings about `import.meta.env.BASE_URL` and child
  compilations remain. iOS/device acceptance was not run on Windows.

The Android artifact is in the React repository at
`android/app/build/outputs/apk/debug/app-debug.apk`. Deployment and publication
were not performed. Deploy backend support and run `data:ensure_unique_indexes`
before releasing updated clients. No checkout backfill is required.

## Catalog and signoff follow-up

- Catalog grants now acquire approver locks before the transaction and retain
  them through commit. A deterministic revocation-at-lock-boundary regression
  uses the real test replica set with mocked Redis; distributed Redis contention
  was not exercised.
- Shop deletion removes active and archived groups before their physical tools.
  Both model and authenticated API regressions passed, including surviving-reference
  rejection before deletion.
- 41 distinct Rails examples passed using their latest results across the catalog,
  group checkout, shop model, and tools API runs. React checkout coverage passed
  45 tests in 13 suites, and TypeScript checking passed.
- The mocked Chromium fixture passed at 320, 600, 900, and 1280 pixels for catalog
  filtering, group load failure, keyboard retry, and group-only approver shop
  selection. Narrow and wide screenshots were reviewed. This is component coverage,
  not authenticated portal or physical-device acceptance.
- Service and collection lifecycle inventories were updated. No environment
  variables or API request/response schemas changed in this follow-up.

## Request resolution, dialog recovery, and Slack follow-up

- All-held group requests resolve through the reviewed API revision without new
  checkouts or credit. Dialog catalog failures preserve existing scope selections,
  expose retry, and block submission until loading succeeds.
- Textual group approvals open their signed Slack modal during the command request.
  Local target lookup supports mentions, usernames, and email; missing links have
  email recovery. Slack reservation previews include group prerequisites without
  applying prerequisite tools' resource policies.
- 88 distinct Rails examples passed using their latest results across focused
  group API, Slack controller/job, reservation preview, and identity lookup runs
  against the supplied test replica set. Slack and Redis were mocked.
- Full React suite: 372 tests in 66 suites passed; TypeScript and the production
  web build passed. Existing webpack BASE_URL/child-compilation warnings remain.
- Mocked Chromium checks passed at 320, 600, 900, and 1280 pixels for dialog retry,
  existing scope preservation, group-only shop selection, and request resolution.
  Narrow/wide screenshots were reviewed. Live Slack, device, and authenticated
  portal acceptance were not performed.
- Executable group response schemas now cover CRUD, checkout review, and volunteer
  responses. Checkout, reservation, service, and UI documentation were updated;
  the environment-variable inventory is unchanged.

Swagger was regenerated successfully (865 dry-run examples; not additional
executed tests), and the generated response schema references were checked.

## Deferred notifications and group overview follow-up

- Slack-sourced approvals queue post-commit group delivery, including both modal
  paths, reconciled announcements, and all-held request resolution. Tests cover
  rollback, enqueue failure without synchronous fallback, and repeat approval.
- Group request annotations follow the current shop instructions. Explicit group
  summaries are batched into approver responses and shown separately in the table.
  Group-list retry and automatic recovery clear old load errors.
- 53 distinct Rails examples passed using their latest results on the supplied
  test replica set; Slack and Redis were mocked. Focused React coverage passed
  53 tests in 15 suites, plus TypeScript and mocked browser checks at 320, 600,
  900, and 1280 pixels. Catalog recovery and approver scope screenshots were reviewed.
- Swagger was regenerated (865 dry-run examples, not additional executed tests)
  and its group summary contract checked. Job/service, checkout, and UX docs were
  updated. No environment variables changed. Release the backend response and
  notification worker before the updated group overview UI. Live Slack and
  physical-device acceptance were not performed.

## Scope selection, workshop recovery and notification snapshots

Whole-shop selection clears the shop's individual and group grants. Workshop Add
Tool retries both management catalogs in the same dialog, including rejected
requests. Slack group notification jobs now carry approval-time catalog details
through Active Job serialization; edits before delivery do not change audit or
message content/channels. Existing queued jobs without snapshots retain legacy
lookup behavior, so drain them before editing catalogs during rollout. Deploy the
updated worker before producers enqueue six-argument jobs. No API/client release
is required; the UI fixes may deploy independently. Environment variables and
collection/index schemas are unchanged.

Validation: 27 distinct Rails examples passed across the group checkout, signed
modal and individual/group notification suites using the designated test MongoDB.
Seven focused React examples and TypeScript passed. The mocked Chromium fixture
passed keyboard retry, recovery and overflow checks at 320/600/900/1280 pixels.
Slack calls were mocked; no live Slack or native-device acceptance was performed.

## Slack group request acknowledgement and cancellation

Both request modal paths queue group announcements/requestor DMs through the
existing notification worker after saving. Stateful Slack and portal group edits
and cancellations now share the catalog and constituent checkout locks with
approval and recheck state within them. The API create response documents both
target variants, including the null physical-tool ID for a group.

Validation: the focused workflow/API/Slack interaction run passed 91 examples;
the final API run passed all 15 examples, including two added portal group mutation
cases (93 distinct examples total). Race tests exercised both winning operations
with real MongoDB transactions and process-local keyed locks replacing Redis.
The designated test MongoDB was used. Slack calls were mocked. Swagger was
regenerated from the executable specs; its dry run is not additional test coverage.
Checkout and jobs documentation were updated. Environment variables and collection
schemas are unchanged. Existing portal types already support group fields;
publishing regenerated API-client types remains a separate release step.
