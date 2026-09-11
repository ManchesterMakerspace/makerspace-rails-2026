# Internal short URLs

Short URLs use the configured APP_DOMAIN and AppDomainUrl protocol rules,
uppercased, followed by `/L` and ten characters from
`23456789ABCDEFGHIJKLMNOPQRSTUVWXYZ`. Only the short URL is uppercased; target
paths keep their case. SHA-256 of the normalized absolute target URL supplies
the base-34 candidate; collisions increment with carry and wraparound.

## Deployment

Before enabling allocation on a deployment, run:

```
bundle exec rake db:mongoid:create_indexes
```

The existing Mongoid index job now runs `shortcodes:ensure_indexes` after its
normal index creation. The shortcode task can also be run independently.
It creates and verifies the separate unique `code` and `target_url` indexes
in `shortcodes`. The release task `data:ensure_unique_indexes` also creates full unique indexes
and replaces older partial or sparse shortcode indexes.
Allocation refuses to proceed without those indexes. No resource backfill is
required; mappings are created when requested. Preserve and back up this
collection: mappings are permanent, immutable, and never recycled. Retain the
public hostname for printed links. Changing protocol/hostname creates distinct
normalized targets; existing mappings are validated against the configured
origin, so hostname moves require an explicit compatibility strategy.

## API and routing

Authenticated `POST /api/shortcodes` takes `{ "target_url": "/api/tool/<id>/public.html" }`
and returns `{ "code": "...", "short_url": "HTTPS://.../L..." }`.
Normal session authentication, TOTP, CSRF, and target visibility apply.
The response is private/no-store. Unavailable resources return 404, unsupported
targets 422, and unavailable storage 503. Supported paths are singular public
shop/tool HTML routes (including `/api` aliases), plural public HTML routes,
`/tools/<id>/request-checkout`, and `/rentals/spots/<id>`. IDs are stable Mongo IDs.
External origins, credentials, query strings, fragments, and shortcode targets
are rejected. Existing long and rental-number URLs remain functional.

GET/HEAD shortcode requests are rewritten internally before Rails routing.
No HTTP redirect expands the short URL; ordinary authentication redirects are
preserved. Incoming query strings are discarded. Existing controllers enforce
permissions and visibility. Public HTML keeps existing caching and cookie rules.
React shells receive an escaped target metadata field, and replace browser
history before mounting the router. Unknown codes return uncached generic 404s;
storage failure without a cache hit returns an uncached 503.

## Cache and QR behavior

`shortcodes:v1:<code>` stores the target in Redis for exactly 86,400 seconds.
Mongo is authoritative; Redis failure or eviction falls back to an indexed
lookup. New mappings are persisted before cache publication. Cache hits do not
read Mongo. No negative cache is used. Do not change the shared Redis eviction
policy: other application keys include operational locks.

Public SVGs and tool/rental QR dialogs encode the exact uppercase short URL,
using alphanumeric QR encoding where supported. Existing error-correction
settings remain. SVGs retain their separate 30-minute render cache and three-day
HTTP lifetime. Old browser-cached SVGs can retain long links for three days.
Rental Copy Link uses the same allocation service as its QR dialog. QR allocation errors are shown without substituting long QR links. Rental
Copy Link falls back to a full URL and displays it for manual copying if needed;
the action is disabled while pending, and changed selections ignore stale results. Email/Slack link generation,
password tokens, and TOTP QR payloads are outside this feature.

Allocation collisions, missing indexes, and backend failures use `[ShortUrl]`
log messages. Errors log classes rather than database credentials or URLs.
