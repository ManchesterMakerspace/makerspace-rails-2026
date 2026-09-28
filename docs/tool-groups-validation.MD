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
