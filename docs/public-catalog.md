# Public shop and tool pages

`/shops/:id/public` and `/tools/:id/public` return public JSON. Append `.html`
for Rails pages. URLs use MongoDB IDs. Hidden tools and tools with hidden or
missing shops return `404 Not Found`, as do malformed and missing IDs.

Public HTML reads the current public projection on every origin request, then
uses a content digest plus `PublicCatalogController::TEMPLATE_VERSION` to cache
rendered HTML in `Rails.cache` for 30 minutes. Production's existing Redis cache
store is used. Cache errors fall back to rendering. Increment the template
version whenever changing the templates or their shared styling. Successful
responses permit browser/shared caching for three days; those copies can remain
visible after an origin edit or disabling. Visibility is checked before ETags.

Create the declared Mongoid indexes as part of normal deployment (`bundle exec
rake db:mongoid:create_indexes`). The tool list index orders by shop and name,
with ID as a stable tie breaker and disabled available for filtering. No record
backfill is needed: absent and null `open` values read as false.

`/tools/:id/request-checkout` authenticates before checking visibility and
serving the SPA shell. Its React form fetches only `/api/tools/:id/coreq.html`
(JSON context despite the historical-style suffix) and submits through the
existing checkout request POST. GET never creates requests. Login return paths
are restricted to stable tool URLs and retained through Firebase and TOTP.
Member-specific responses are private and not stored.

An open tool remains visible with “No checkout required”. New requests are
blocked in the API, Slack and model validation. Existing requests/checkouts and
administrative grants remain intact. Reservations omit only the automatic
self-checkout requirement; explicit prerequisites remain required.

Focused verification:

```sh
bundle exec rspec spec/requests/public_catalog_spec.rb spec/requests/checkout_links_spec.rb spec/models/tool_open_spec.rb spec/requests/pending_tool_checkout_requests_spec.rb spec/jobs/slack_checkout_request_job_spec.rb spec/controllers/sessions_controller_spec.rb spec/models/reservation_spec.rb
```

Build the React assets before Rails HTML request tests. The suite requires an
explicitly configured test `MLAB_URI` and clears that test database.

React verification (from the React repository):

```sh
npm run typecheck
npm test -- --runInBand tests/unit/checkoutDestination.spec.ts
npm run build
node tests/browser/checkout-links.cjs
```

The browser check uses mocked APIs, verifies password/TOTP return navigation,
keyboard submission, and form states at 320, 600, 900 and 1440px. It uses Edge
on Windows or Playwright Chromium elsewhere; `BROWSER_CHANNEL` overrides this.
