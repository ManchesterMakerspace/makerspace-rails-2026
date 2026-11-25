# WelcomePi MQTT

WelcomePi subscribes to door arrivals and changes to the Rails member and card directory. The kiosk and its commissioning tools use a **read-only broker account**. A local PN532 tap controls the display locally. All MQTT publishing for these feeds happens upstream.

## Configure the Pi

Edit `/etc/welcomepi.env` on the Pi and restart `welcomepi.service` after saving. The installer creates this file with mode `0600`. [Example environment](welcomepi.env.example)

| Variable | Requirement and meaning |
| --- | --- |
| `MQTT_HOST` | Required. Broker hostname, for example `mqtt.example.org`. |
| `MQTT_TLS` | Defaults to `true`. Set to `false` for a plaintext listener. |
| `MQTT_CAFILE` | Optional path to a PEM file containing the trusted CA certificate or bundle for the TLS broker. Unset or empty uses the OS trust store. The kiosk, `check` and `watch-door` all use this setting when TLS is enabled. |
| `MQTT_PORT` | Optional integer. Defaults to `8883` with TLS and `1883` with TLS disabled. |
| `MQTT_USERNAME`, `MQTT_PASSWORD` | Set both for the password-authenticated ACL below. The client sends credentials only when a username is configured. |
| `MQTT_CLIENT_ID` | Defaults to `welcomepi-<hostname>`. Each running kiosk needs a unique ID. Commissioning uses a separate generated `wpi-check-…` ID with the same credentials. |
| `MLAB_URI`, `LEDGER_URI` | Both are required at startup, including for commissioning. Provide read-only MongoDB URIs with the Rails and Ledger database names respectively. |
| `WELCOMEPI_LOCATION_PATTERNS` | Optional JSON array of case-insensitive regexes, e.g. `["^Main Entrance$"]`. Unset allows greetings from every door. An empty array keeps door arrivals history-only. Matching uses the document's `where`, then `reader`, then the literal `blank:`. |

For a broker signed by a private CA, copy the CA's public certificate to the Pi, for example to `/etc/welcomepi/broker-ca.pem`, and make it readable by the `welcomepi` service account. Set `MQTT_CAFILE=/etc/welcomepi/broker-ca.pem` in `/etc/welcomepi.env`. Use a hostname in `MQTT_HOST` that matches the broker certificate. An unreadable or invalid CA file causes MQTT startup to fail.

## What crosses the broker

| Publisher | Topic or subscription filter | What WelcomePi does |
| --- | --- | --- |
| Door activity publisher | `activity/checkins/#` | Receives activity such as `welcome` and `processed`. The last topic segment identifies the sending reader. A fresh name-only arrival can show a first-name greeting. A card UID lets the kiosk look up the assigned member and check eligibility for the agenda. |
| ChangeStream2MQTT | `checkins/insert` | Receives the inserted check-in. The kiosk reconciles copies of the same tap across both feeds. Arrivals from excluded locations can still update **Recent check-ins**. |
| ChangeStream2MQTT | `members/insert`, `members/update`, `members/replace`, `members/delete` | Updates or removes entries in the local member directory. |
| ChangeStream2MQTT | `cards/insert`, `cards/update`, `cards/replace`, `cards/delete` | Updates or removes card assignments used to resolve UIDs. |

Messages start with an operation and its Unix publication time in seconds, followed by the document body. Change-stream messages use a `{"document": …}` envelope and the operation from the topic. Door activity also accepts a bare check-in document. The kiosk uses both the publication time and the check-in time to decide whether to wake the display. Both must be less than two minutes old and at most ten seconds ahead of the Pi. Retained check-ins do not trigger a greeting. Retained or incomplete directory updates trigger a directory refresh from MongoDB. [Message handling](welcomepi/inputs.py) · [Check-in parser](welcomepi/checkin_payload.py)

The kiosk opens a clean session and requests all ten subscriptions at QoS 2 on each connection. It accepts broker grants of QoS 0, 1 or 2 and retries a missing subscription acknowledgment after 20 seconds.

## Minimal Mosquitto ACL

The example assumes an existing authenticated broker with `allow_anonymous false` and a password file. Point `acl_file` at the ACL file containing these entries. Each `user` is a **broker username**. Replace the example reader ID `reader-01` with the final topic segment used by that door. On a shared broker, merge these entries with the permissions its other applications need. [Mosquitto ACL reference](https://mosquitto.org/man/mosquitto-conf-5.html)

```text
user welcomepi
topic read activity/checkins/#
topic read checkins/insert
topic read members/insert
topic read members/update
topic read members/replace
topic read members/delete
topic read cards/insert
topic read cards/update
topic read cards/replace
topic read cards/delete

user changestream2mqtt
topic write checkins/insert
topic write members/insert
topic write members/update
topic write members/replace
topic write members/delete
topic write cards/insert
topic write cards/update
topic write cards/replace
topic write cards/delete

user door-reader-01
topic write activity/checkins/reader-01
topic write activity/checkins/activeMember/reader-01
```

The two door rules illustrate a reader that publishes both processed and welcome messages on those paths. Give each door account only the concrete paths it publishes. The change-stream rules cover the collections and operations WelcomePi consumes. A bridge serving additional consumers needs separate grants for their topics.

Configure the bridge credentials on the **ChangeStream2MQTT host** using `MQTT_USER` and `MQTT_PW`. Its connection uses `MQTT_HOST` and `MQTT_PORT` (default `1883`), and its MongoDB source uses `CHANGE_STREAM_DB`. The bridge implementation uses plain MQTT, so its listener or local TLS tunnel must match that transport.

## Verify delivery

At the kiosk's configured syslog destination, **DEBUG** marks receipt on either check-in feed before parsing. **INFO** marks a greeting or accepted scan. **WARNING** explains skipped welcomes. **ERROR** marks a failed member identification. A name-only public greeting may produce both a greeting entry and an identification error. [Kiosk logging](README.md)

1. On the Pi, from the transferred WelcomePi directory, run `sudo bash setup.sh check`. The expected acknowledgment is **MQTT acknowledged all 10 kiosk subscriptions.**
2. Run `sudo bash setup.sh watch-door`, wait for **Listening**, then use a working fob at a matching door. The observer waits up to 90 seconds and reports the received topic and whether the record included a UID. This checks actual delivery with the kiosk account. [Door commissioning procedure](setup-pi0.MD)
