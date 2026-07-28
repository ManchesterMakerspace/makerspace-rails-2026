# Makerspace Rails
Application to handle member management at the Manchester Makerspace.  Connects with
key fob system for facility entry and Braintree API for payment processing.

# Development

1. Configure `.env` file
See `sample.env` for required environment variables per feature.
Contact @lynch16 for variables for the Manchester Makerspace.
2. Spin up rails server
```
$ rails s
```

### Wiki URLs

Set `WIKI_URL` to the public wiki base URL, without a required trailing slash:

```env
WIKI_URL=https://wiki.manchestermakerspace.org
```

The React footer uses this runtime value. Shops and tools may store an explicit
Wiki URL. When blank, shop links default to
`<WIKI_URL>/workshops/<slugified-shop-name>` and tool links default to
`<WIKI_URL>/workshops/<slugified-shop-name>#<slugified-tool-name>`. Slugs are
lowercase and punctuation/whitespace are converted to hyphens.

Authenticated members can browse these links at `/workshops`. Disabled shops
are restricted to admins and board members. Hidden tools are shown only to
admins/board, the shop's resource managers, or members with an active checkout
for that tool.

## With Docker

1. Install [Docker](https://docs.docker.com/get-started/get-docker/)
2. Run `docker compose up` in the repo directory. Will take several minutes on the first run.
3. Visit http://localhost:3000
4. **To stop the server:** `docker compose down`
5. **To open a Rails console:** `docker compose exec web rails console`
6. **To open a [Mongo console](https://www.mongodb.com/docs/mongodb-shell/):** `docker compose exec db mongosh admin`

# Importing an archived db or Restoring production to development
First dump production to a local backup folder
```
mongodump --uri "<uri for prod db>" -o ./dump
```
Then restore to development server
```
mongorestore --uri "<uri for dev db>" dump/ --drop
```


# Testing
Rspec is used for unit testing the ruby backend.
```
$ rspec
```
Selenium integration tests for the [makerspace-react](https://github.com/ManchesterMakerspace/makerspace-react) can be run with
```
$ rake integration
```
Emails in the development environment are published to MailTrap under the adgrants@ user in Lastpass. To preview emails, you can view them in the browser by starting a server with `TEST_MAIL=true rails s`; this will start a development server, which will preview emails, using a test database to hydrate values for all the mocks. If you need to test that the emails actually sent, you may use `MAILTRAP_API_TOKEN` environment variable in the development environment. 

# Swagger
An OpenSwagger spec of the JSON API can be generated or updated with `rake rswag:specs:swaggerize`. To view an interactive version of this swagger, start a development server with `rails s` and navigate to `/api-docs`

## Public reservation agenda

`GET /reservations/agenda?shop=Woodshop` returns an unauthenticated HTML agenda
covering the next 24 hours. Add a case-insensitive exact tool name to filter the
agenda:

```
/reservations/agenda?shop=Woodshop&tool=Planer
```

Use `/reservations/agenda.json` or an `Accept: application/json` header for JSON.
The JSON response includes the selected shop/tool, window timestamps, `upNext`,
and pending or approved reservations, including reservations already in progress.
Tool-filtered agendas also include whole-shop reservations. Missing `shop` returns
400; unknown shops or tools return 404. Blackouts are not included in this public
endpoint.

Example:

```json
{
  "shopName": "Woodshop",
  "toolName": "Planer",
  "generatedAt": "2026-07-28T14:00:00Z",
  "windowStart": "2026-07-28T14:00:00Z",
  "windowEnd": "2026-07-29T14:00:00Z",
  "upNext": {
    "memberName": "Ada Lovelace",
    "slackUsername": "ada",
    "startAt": "2026-07-28T15:00:00Z"
  },
  "reservations": [
    {
      "title": "Cabinet doors",
      "memberName": "Ada Lovelace",
      "slackUsername": "ada",
      "startAt": "2026-07-28T15:00:00Z",
      "endAt": "2026-07-28T17:00:00Z",
      "status": "approved",
      "reservationScope": "tools",
      "toolNames": ["Planer"],
      "inProgress": false
    }
  ]
}
```

`upNext` is only populated for a tool-filtered request. It selects the earliest
future reservation in the window, never an in-progress reservation. In HTML it is
rendered as `Up Next @SLACKUSERNAME at HH:MM`, falling back to the member's full
name when no Slack account is linked. Agenda rows contain time, title, full member
name, Slack username, resources, and status as plain text. The HTML view includes
a top-right menu for switching between the whole-shop agenda and each visible,
reservable tool in that shop.

Set the `reservation_token` portal setting or the `RESERVATION_TOKEN` environment
variable to protect both formats. When configured, callers must append the exact
token as `?token=...`; an absent or incorrect token returns 403. The portal value
takes precedence over the environment value. When neither value is configured the
endpoint is public.

# CONTRIBUTIONS

Bug reports and pull requests are welcome on GitHub at https://github.com/ManchesterMakerspace/makerspace-interface. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the Contributor Covenant code of conduct.

All pull requests require Travis CI tests to pass before being merged.

# LICENSE

The app is available as open source under the terms of the MIT License.
