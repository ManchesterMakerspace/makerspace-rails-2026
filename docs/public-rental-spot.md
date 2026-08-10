# Public Rental Spot

## Purpose

Returns non-sensitive catalog information for a rental spot before sign-in,
supporting durable QR codes and deep links.

## Canonical URL

`GET /api/rental_spots/:id/public`

## Audience

QR-code visitors and pre-login Member Portal landing pages.

## Authentication and token handling

No member session or token is required.

## Identifiers and query parameters

`id` is required in the path and may be a legal MongoDB object ID or the spot's
human-readable, case-sensitive `number`. There are no query parameters.

## Formats

JSON only; the `/api` scope defaults the response format to JSON.

## Response and error behavior

Success returns the public rental-spot serializer representation. If neither an
object ID nor a spot number resolves, Rails handles a Mongoid
`DocumentNotFound` error as a not-found response.

## Examples

```text
GET /api/rental_spots/LR-Tote-1/public
GET /api/rental_spots/507f1f77bcf86cd799439011/public
```

## Privacy considerations

Only fields approved by `RentalSpotPublicSerializer` may be returned. Additions
to that serializer change the public data contract and require privacy review.

## Operational configuration

No token or environment configuration is required. QR codes should use the
stable human-readable number when administrators need links that do not expose
database identifiers.
