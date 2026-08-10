# Public Volunteer Resources

## Bounties

### Purpose

Lists currently claimable parent volunteer tasks, optionally filtered by shop.

### Canonical URL

`GET /volunteer/bounties`

### Audience

Public displays, prospective volunteers, and data integrations.

### Authentication and token handling

No member session is required. When volunteer token gating is enabled, `token`
must securely match the configured shared token or the response is `403`.

### Identifiers and query parameters

There are no required parameters. `shop` optionally performs a URL-decoded,
case-insensitive substring match on shop name. `token` is conditionally required.

### Formats

HTML is the default; JSON and XML are selected by `.json`/`.xml` or negotiation.

### Response and error behavior

Results are ordered by task number and exclude child and cooling-down recurring
tasks. Machine formats expose task ID/number, title, description, credit value,
status, shop, prerequisite tools, claim time, and next availability. A failed
token check returns `403`; an empty result is successful.

### Examples

```text
/volunteer/bounties
/volunteer/bounties.xml?shop=WOOD
/volunteer/bounties.json?token=REDACTED
```

### Privacy considerations

Bounties intentionally expose task descriptions and shop associations. Do not
place private instructions in public task fields or publish shared tokens.

### Operational configuration

Set `volunteer_bounty_token_enabled`/`VOLUNTEER_BOUNTY_TOKEN_ENABLED` to `true`
and provide `volunteer_bounty_token`/`VOLUNTEER_BOUNTY_TOKEN` to gate access.
Portal settings take precedence when present.

## Leaderboard

### Purpose

Publishes a ranked lifetime volunteer-credit leaderboard.

### Canonical URL

`GET /volunteer/leaderboard`

### Audience

Public displays, browsers, and JSON integrations.

### Authentication and token handling

No member session is required. It uses the same optional shared-token gate as
the bounties resource; a missing or incorrect required token returns `403`.

### Identifiers and query parameters

There are no required identifiers. `token` is conditionally required. The
number of entries is server-configured rather than caller-controlled.

### Formats

HTML is the default; JSON is selected by `.json` or negotiation.

### Response and error behavior

Approved credits and reversals are summed by member, deleted members are
omitted, and remaining entries are reranked. Each entry contains rank, member
full name, and lifetime credits rounded to one decimal. An empty leaderboard is
successful; a failed token check returns `403`.

### Examples

```text
/volunteer/leaderboard
/volunteer/leaderboard.json?token=REDACTED
```

### Privacy considerations

The leaderboard publicly exposes member full names and aggregate credits.
Operators should confirm that public display is appropriate and protect tokens
from logs, screenshots, analytics, and referrer URLs.

### Operational configuration

`volunteer_leaderboard_top` controls the entry count (default `10`). Token gating
uses the bounty enable/token portal settings or the corresponding environment
variables described above.
