# Public Reservation Agenda

## Purpose

Provides a read-only 24-hour reservation agenda for a shop or one of its tools.

## Canonical URL

`GET /reservations/agenda?shop=Woodshop`

## Audience

Shop displays, kiosks, and browser or JSON clients.

## Authentication and token handling

No member session is required. If the `reservation_token` portal setting or
`RESERVATION_TOKEN` is nonblank, `?token=...` must match it; the portal setting
takes precedence. A missing or incorrect configured token returns `403`.

## Identifiers and query parameters

`shop` is required and is a case-insensitive exact shop-name match. `tool` is an
optional case-insensitive exact tool-name match within that shop. `token` is
conditionally required as described above. Disabled shops and tools are hidden.

## Formats

HTML is the default. Use `.json` or `Accept: application/json` for JSON.

## Response and error behavior

The agenda covers now through 24 hours from now and includes pending/approved
reservations already in progress. A tool agenda also includes whole-shop
reservations. JSON contains `shopName`, `toolName`, timestamps, `upNext`, and
`reservations`; `upNext` is only populated for a tool and excludes in-progress
reservations. Blackouts are excluded. Missing `shop` returns `400`; an unknown or
disabled shop/tool returns `404`; a failed token check returns `403`.

## Examples

```text
/reservations/agenda?shop=Woodshop&tool=Planer
/reservations/agenda.json?shop=Woodshop&tool=Planer&token=REDACTED
```

## Privacy considerations

Rows expose reservation titles, member full names, Slack usernames, times,
resources, and status. Treat unprotected displays and URLs containing tokens as
sensitive; do not log, publish, or embed real tokens in documentation.

## Operational configuration

Set `reservation_token` in portal settings (preferred) or `RESERVATION_TOKEN` in
the environment to gate access. With both blank, the resource is openly public.
