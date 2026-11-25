# WelcomePi

WelcomePi is a read-only entrance kiosk for Raspberry Pi OS Lite **Trixie or Bookworm**. It draws directly to one HDMI display with Pillow and KMS. A successful door check-in or a tap on the local PN532 wakes the display and greets a member. Local taps only control this screen.

For a **Pi Zero W at 720p**, follow the [step-by-step setup guide](setup-pi0.MD). It covers the workstation transfer, GPIO wiring, Pi installer and separate first-welcome checks at the kiosk and the door. A working kiosk can [enroll for automatic updates from master](setup-pi0.MD#8-enable-automatic-updates-from-master).

## Install on a Pi 4 or Pi 5

1. In Raspberry Pi Imager, choose your board and **Raspberry Pi OS Lite (64-bit)** for Debian 13 (Trixie) or the Legacy Lite image for Debian 12 (Bookworm). Both Pi 4 Model B and Pi 5 support this image. Pi 4B can also use 32-bit Lite on either release. Enable SSH and configure networking. With the Pi powered off, connect the monitor to the micro-HDMI socket marked **HDMI0** or **HDMI1**. [Raspberry Pi OS images](https://www.raspberrypi.com/software/operating-systems/)
2. If using a PN532, choose I²C or UART and follow the [40-pin header wiring table](setup-pi0.MD#2-wire-the-pn532-while-power-is-disconnected). For I²C, run `sudo raspi-config nonint do_i2c 0` on the Pi before reboot. For GPIO UART, a fresh install sets `WELCOMEPI_NFC_PORT=/dev/serial0` on Pi 4B and `/dev/ttyAMA0` on Pi 5. Check this setting when reusing an environment file on another board. On a stock Pi 5, `/dev/serial0` points to the dedicated debug header. [Raspberry Pi UART configuration](https://www.raspberrypi.com/documentation/computers/configuration.html#configure-uarts)
3. From the workstation, transfer the kiosk and connect to the Pi. Substitute your SSH login and hostname.

   ```sh
   cd tools/WelcomePi
   bash workstation/setup.sh makeradmin@welcomepi.local
   ssh makeradmin@welcomepi.local
   ```

4. On the Pi, run the installer and edit the service environment. Supply the [site credentials](#configuration-and-access) and set `WELCOMEPI_HDMI_PORT` using the table below. Then run `sudo reboot`. The Pi 4/5 installer leaves the HDMI resolution to KMS and preserves any existing per-connector `video=` mode.

   ```sh
   cd ~/WelcomePi
   sudo bash setup.sh install
   sudoedit /etc/welcomepi.env
   ```

   | `WELCOMEPI_HDMI_PORT` | Where the kiosk appears |
   | --- | --- |
   | `auto` (default) | First connected HDMI output. With both onboard sockets connected, HDMI0 is first. |
   | `0` | Socket labelled **HDMI0**, Linux connector `HDMI-A-1`. |
   | `1` | Socket labelled **HDMI1**, Linux connector `HDMI-A-2`. |

   A fixed selection keeps member greetings and standby on that socket. If you unplug its monitor, the kiosk waits for it to reconnect. The other socket can still show the Linux console. [Raspberry Pi KMS connector names](https://www.raspberrypi.com/documentation/computers/configuration.html#set-the-kms-display-mode)

5. After reconnecting over SSH, run `cd ~/WelcomePi && sudo bash setup.sh check`, then `sudo systemctl enable --now welcomepi.service`. Confirm the board appears on the intended monitor. Use `kmsprint` to inspect active modes and `grep -H . /sys/class/drm/card*-HDMI-A-*/status` to match connector names to the connected cables. Complete the [local and door welcome checks](setup-pi0.MD#7-verify-each-first-welcome).

To switch sockets later, change `WELCOMEPI_HDMI_PORT` in `/etc/welcomepi.env` and run `sudo systemctl restart welcomepi.service`.

### Adjust overscan and text weight

If the monitor cuts off the top and right edges, try these values in `/etc/welcomepi.env`. Restart with `sudo systemctl restart welcomepi.service` and adjust the pixel counts to fit your monitor.

```ini
WELCOMEPI_INSET_TOP=16
WELCOMEPI_INSET_RIGHT=24
WELCOMEPI_FONT_STROKE=1
```

Set `WELCOMEPI_INSET` for a margin on all four sides (default 0). Each of `WELCOMEPI_INSET_TOP`, `WELCOMEPI_INSET_RIGHT`, `WELCOMEPI_INSET_BOTTOM` and `WELCOMEPI_INSET_LEFT` replaces that side's value, including when set to 0. Edges follow the upright picture on a rotated monitor. The kiosk lays out every page inside the remaining space and fills the margins with black.

`WELCOMEPI_FONT_STROKE` thickens text on every screen. Start with 1 pixel for small labels. The supported range is 0 (default) through 3 pixels.

## Choosing an older board

| Board on hand | Fit for the kiosk |
| --- | --- |
| Pi Zero W, 512 MB | First choice for a low-power installation. Its 1 GHz single-core ARM11 and memory match the original Zero target, and it has 2.4 GHz Wi-Fi. Use mini HDMI and a populated GPIO header for the PN532. [Zero specifications](https://www.raspberrypi.com/documentation/computers/zero.html) |
| Pi 1, 512 MB | Oldest candidate to try. A later 2012 Model B or a Model B+ has a 700 MHz single-core ARM11 and built-in Ethernet. Start at 1280×720 and measure the greeting on that board. Some Pi 1 revisions have only 256 MB. Look up the value from `grep '^Revision' /proc/cpuinfo` before choosing one. [Board specifications](https://www.raspberrypi.com/documentation/computers/sbcs.html) · [Revision table](https://www.raspberrypi.com/documentation/computers/raspberry-pi.html#raspberry-pi-revision-codes) |
| Pi 2 Model B, 1 GB | Wired option with four CPU cores and more room for a 1080p portrait display. [Board specifications](https://www.raspberrypi.com/documentation/computers/sbcs.html) |

Select **Raspberry Pi OS Lite (32-bit)** for Trixie or **Legacy Lite (32-bit)** for Bookworm. The earliest 256 MB Pi 1 boards are experimental for this kiosk. At 720p the two HDMI buffers occupy about 7 MiB, rising to 16 MiB at 1080p, before Pillow's working images, Python, the member cache, and the OS. The 500 ms greeting target and monitor wake behavior require on-device measurement. [Raspberry Pi OS downloads](https://www.raspberrypi.com/software/operating-systems/)

## Install on a Pi Zero or Pi 3B+

1. Connect HDMI and networking. An original Zero needs a network adapter and may need a soldered GPIO header. With power disconnected, select **I²C** or **HSU/UART** on the PN532 breakout. For I²C connect SDA to physical pin 3 and SCL to pin 5. For UART connect breakout TX to pin 10 and RX to pin 8. Connect ground, follow the board's supply specification, and use 3.3 V logic and pull-ups. [Pi Zero wiring guide](setup-pi0.MD#2-wire-the-pn532-while-power-is-disconnected)
2. In `sudo raspi-config` under **Interface Options**, enable **I2C** for an I²C board. For UART, select **Serial Port**, disable the serial login shell and enable serial hardware. Reboot. WelcomePi probes the configured Linux I²C adapter for PN532 firmware, then tries the configured UART. A USB-to-UART adapter can use its stable `/dev/serial/by-id/...` path. With no local reader the kiosk keeps listening for door check-ins and retries discovery. Both transports preserve the ISO 14443-A UID's byte order and leading zeroes. [Linux I²C interface](https://docs.kernel.org/i2c/dev-interface.html) · [nfcpy serial configuration](https://nfcpy.readthedocs.io/en/latest/topics/get-started.html)
3. Use the full `vc4-kms-v3d` graphics driver and dedicate the HDMI output to the kiosk. Check the connected display with `kmsprint`. Keep console blanking disabled (`consoleblank=0` on the existing single kernel command line in `/boot/firmware/cmdline.txt`) so the kiosk owns the standby timer. Detect rotation automatically or set an override below. [Pi display configuration](https://www.raspberrypi.com/documentation/computers/configuration.html#set-the-kms-display-mode)
   To try 720p on a slower Pi with a compatible monitor, append `video=HDMI-A-1:1280x720@60` to the same line and reboot. Use the connector name reported by `kmsprint`.
4. From this tool directory in the checkout, install the system libraries and service. The virtual environment inherits the distribution's Pillow, MongoDB driver, and KMS bindings. This avoids depending on ARMv7 binary wheels on the ARMv6 Zero. [Raspberry Pi KMS Python bindings](https://github.com/raspberrypi/pykms)

```sh
sudo apt update
sudo apt install python3-venv python3-kms++ kms++-utils python3-pil python3-pymongo \
  python3-dnspython python3-paho-mqtt python3-qrcode python3-serial python3-usb1 \
  libusb-1.0-0 i2c-tools ca-certificates fonts-dejavu-core tzdata
sudo useradd --system --user-group --no-create-home --shell /usr/sbin/nologin welcomepi
sudo install -d /opt/welcomepi
sudo cp -R welcomepi requirements.txt /opt/welcomepi/
sudo python3 -m venv --system-site-packages /opt/welcomepi/.venv
sudo /opt/welcomepi/.venv/bin/pip install -r /opt/welcomepi/requirements.txt
sudo install -m 600 welcomepi.env.example /etc/welcomepi.env
sudoedit /etc/welcomepi.env
sudo install -m 644 welcomepi.service /etc/systemd/system/welcomepi.service
sudo systemctl daemon-reload
sudo systemctl enable --now welcomepi
journalctl -t welcomepi -f
```

For an upgrade, replace the code and dependencies under `/opt/welcomepi`, install the updated unit, run `systemctl daemon-reload`, and restart `welcomepi`. Keep the configured environment file. Stop the kiosk with `sudo systemctl stop welcomepi`.

## Configuration and access

Set values in `/etc/welcomepi.env`. Restart the service after edits.

| Variable | Use |
| --- | --- |
| `MLAB_URI`, `LEDGER_URI` | Required. Read-only MongoDB URIs including the Rails source and Ledger database names respectively. Use the source database watched by ChangeStream2MQTT, normally `makerauth`. |
| `MQTT_HOST`, `MQTT_PORT`, `MQTT_TLS` | Host required. TLS defaults to `true` with port 8883. Explicit `false` defaults to 1883. |
| `MQTT_CAFILE` | Optional PEM CA bundle for verifying the broker. Leave unset to use the OS trust store. [MQTT configuration](MQTT.MD#configure-the-pi) |
| `MQTT_USERNAME`, `MQTT_PASSWORD`, `MQTT_CLIENT_ID` | Broker credentials if required. The default client ID is `welcomepi-<hostname>`. Give each kiosk a unique ID. |
| `WELCOMEPI_LOCATION_PATTERNS` | JSON array of case-insensitive regexes for door welcomes. For example, `WELCOMEPI_LOCATION_PATTERNS='["^Main Entrance$","^Lobby Reader-"]'` matches the entire first location or any location with the second prefix. Unanchored expressions match anywhere. Unset allows all locations. `[]` makes all MQTT arrivals history-only. |
| `WELCOMEPI_I2C_BUS`, `WELCOMEPI_I2C_ADDRESSES` | Default `/dev/i2c-1` and `0x24`. For an address translator, list the mapped 7-bit addresses in probe order, separated by commas. |
| `WELCOMEPI_NFC_PORT` | UART fallback after the I²C probe. Defaults to `/dev/serial0`. The Pi 5 installer sets `/dev/ttyAMA0` for the 40-pin header on first install. |
| `WELCOMEPI_SYSLOG_HOST`, `WELCOMEPI_SYSLOG_PORT` | Set both to send application logs directly to a collector's IPv4 or IPv6 address and UDP port. Leave both unset for local syslog. |
| `WELCOMEPI_HDMI_PORT` | Defaults to `auto` for the first connected output. Set `0` for HDMI0 or `1` for HDMI1 on Pi 4B and Pi 5. |
| `WELCOMEPI_ROTATION` | `auto` uses the active plane, connector orientation, kernel display settings, or console rotation. `left` rotates the rendered image counterclockwise, `right` clockwise, and `normal` uses no rotation. A monitor without orientation metadata needs an override if mounted sideways. |
| `WELCOMEPI_LAYOUT_INTERVAL_MINUTES` | Positive whole minutes between changes of layout and colors while the public board stays on screen. Defaults to 7. |
| `WELCOMEPI_DIM_AFTER_MINUTES` | Positive whole minutes since the last fresh door check-in or distinct local fob tap before the public board dims. Defaults to 15. |
| `WELCOMEPI_OPPORTUNITIES` | Positive integer, default 5. The generic board lists up to 10. |
| `EVENTBRITE_ORGANIZATION_IDS` | Match Rails' comma-separated organization IDs. Empty permits all synced organizations. |
| `SLACKIDS_INELIGIBLE` | Match Ledger's Slack exclusions. Accepts a JSON list or its quoted brace-delimited set. Default empty. |
| `WELCOMEPI_SLACK_TOKEN` | Enables generated artwork. The credential on the Pi needs `files:read` **and access to the Ledger bot's private DM file**. An unrelated bot with the same scope cannot read that file. Without an accessible thumbnail, the character sheet uses a rank icon. [Slack file permissions](https://docs.slack.dev/reference/methods/files.info/) |

Grant MongoDB **find** access on these collections only. Aggregations use the same read privileges. WelcomePi writes no check-ins, claims, acknowledgments, or profile changes.

| Database | Collections |
| --- | --- |
| Rails | `members`, `cards`, `checkins`, `reservations`, `shops`, `tools`, `tool_checkouts`, `volunteer_tasks`, `volunteer_events`, `volunteer_credits`, `fix_tickets`, `eventbrite_events`, `slack_users` |
| Ledger | `ledger_participants`, `ledger_catalog`, `ledger_awards`, `ledger_evidence`, `ledger_avatars` |

Grant the kiosk subscribe-only access to `activity/checkins/#`, `checkins/insert`, and each of `insert`, `update`, `replace`, `delete` under `members/` and `cards/`. Grant the wildcard subscription before updating an existing kiosk. Limit publishing on these topics to the trusted door and change-stream publishers. ChangeStream2MQTT sends **full member documents**, including sensitive fields. WelcomePi projects identity fields before queuing an event and keeps the directory, recent arrivals, agenda, kudos, and private image bytes in RAM.

For check-in topics, the payload starts with `welcome`, `processed` or `insert`, followed by a Unix timestamp in seconds or milliseconds and a record. WelcomePi accepts JSON, MongoDB Extended JSON and Mongo shell records, either directly or inside a `document` object. The final activity topic segment identifies the sending reader, as in `activity/checkins/activeMember/Reader01` or `activity/checkins/Reader01`. The kiosk reads the card UID from the document's `uid` or `cardUID` field. If both are present they must identify the same card to open a personalized agenda. It filters using the document's `where`, then `reader`, then the literal `blank:` even when the topic identifies the sending reader. To welcome a member whose record lacks both location fields, include `^blank:$` in a selective location list.

**Application logs** use syslog's `daemon` facility and `welcomepi` tag. On the Pi the default destination is `/dev/log`. Follow it with `sudo journalctl -b -t welcomepi -f`. On systems without a syslog socket the service writes to the local journal via stderr. A configured remote collector receives UDP datagrams directly with the kiosk hostname. The Pi keeps the delivery queue in RAM. UDP carries member names in clear text, so select a collector and network approved for attendance records.

- **INFO** records the selected PN532 interface, local card presentations and door arrivals. A verified scan includes the member's first and last name. For a local scan the log identifies the transport and device. For an MQTT scan it includes the received topic and the resolved location. On an activity topic, the final segment identifies the sending reader. A location mismatch is logged and the arrival still counts toward **Recent check-ins**. Local taps only control the screen. Retained and duplicate MQTT deliveries do not trigger another welcome.
- When the display loses its HDMI connection, a **WARNING** names the socket and cable to check. A missing fixed display also triggers the warning at startup. Reconnecting it produces an **INFO** recovery message. Both messages go to the configured log and to stderr once per transition. A sleeping monitor can drop its connection signal, so the kiosk checks for persistent loss after wake. To watch stderr on the Pi, use `sudo journalctl -b -u welcomepi.service -f`, including with remote syslog enabled.
- **WARNING** reports MQTT-only operation when neither reader responds. Every unverified scan also gets a warning explaining whether eligibility or a lookup failure prevented identification.
- **ERROR** records MQTT socket/TLS, connection, subscription and keepalive failures, and MongoDB query, server-selection and heartbeat failures with their driver messages. Credentials and echoed MongoDB commands are filtered from application logs.

## Operation

- A fresh check-in with a name from a matching door can display the recorded first name immediately in the largest type that fits. A name-only welcome stays public until the kiosk receives the scanned card’s UID, for example in a fuller record of the same tap. The member can also tap their own active fob on the kiosk reader. An open private details screen keeps priority over a name-only arrival.
- To load the agenda, WelcomePi looks up the card UID in its directory or queries MongoDB in the background, then uses the card’s `member_id` to load the member. The card must be active and the linked member must be unmerged, fully active and unexpired. Local taps work independently of the location filter. The name moves into a smaller header as soon as there are reservations or volunteer opportunities to show. If both are empty, the agenda appears when all three reads finish, including today's Eventbrite listings. Held reservations include pending and unpaid time. The day, weekday and checkout expiration use Manchester time.
- While the agenda is visible, lift and present the same member's fob locally to open their character sheet or received kudos and tool checkouts. **Everyone near the display can read the full kudos text, including DM-only messages.** Only recipient-delivered kudos appear. Tap the same fob again to clear the details.
- A different local fob takes over immediately. On a secondary page the newest other verified door arrival waits for at most the first 30 seconds after entry. A local dismissal cancels that handoff. Two idle minutes clear personal details. Four idle hours disable HDMI output while both listeners remain active.
- **Recent check-ins** shows the five most recently seen members across all locations, each with their latest arrival in the past 16 hours. The kiosk keeps up to ten distinct members in RAM. Multiple cards linked to the same member count as one person. A first-name-only welcome can be matched to a fuller record from the same door within ten seconds. At startup the kiosk reads the window from MongoDB and merges arrivals received during that read. Thereafter it updates the cache from MQTT, ages entries out as time passes, and uses this cache on board refreshes and after reconnecting. A check-in after midnight can appear alongside arrivals from the previous evening.
- The generic board also shows lifetime approved volunteer credits including signed reversals and globally claimable work. Required rows rotate through pages every eight seconds if necessary. A phone can open the portal using the QR code. Check-in delivery, cache rebuilds, and page cycling never generate new door records.
- To reduce monitor burn-in, the public board alternates light and dark colors and moves the portal QR through four corners. It advances when it reopens or after seven minutes on screen by default. Greetings, agendas and details each get a different layout on the next visit. Their colors and positions stay steady while you read or wait for more rows.
- After 15 minutes without a fresh check-in or distinct local fob tap, WelcomePi draws the public board at reduced brightness. Greetings and personal pages stay at normal brightness. A fresh check-in from any door or a new local tap brightens the awake board. A history-only door or unrecognized local fob leaves the page and its existing timeouts in place. To repeat a tap, lift the fob and present it again. Once in standby, a qualifying scan is needed to wake HDMI.
- The kiosk subscribes before loading its directory and reconciles changes received during that read. It rebuilds on reconnect, on ambiguous identity messages, and every five minutes while connected. On a gap it clears personal data and verifies new scans directly against MongoDB. A disconnected reader retries independently. Failed section reads retry on refresh. History is displayed on the board without waking the screen for replayed arrivals.

## Verification

Run from this directory on a development machine with Python 3.11 or newer. The suite uses synthetic documents, a fake clock, a memory-backed display, and the publisher's wire format. To exercise the queries against a **disposable local MongoDB**, set `WELCOMEPI_TEST_MONGO_PORT` to its loopback port. Each test creates and removes only its randomly named test databases.

```sh
python3 -m venv .venv
.venv/bin/pip install -r requirements-test.txt
.venv/bin/python -m unittest discover -v -s tests
```

On each target model, verify the following using test accounts and fobs.

1. Boot with HDMI connected, then unplug and reconnect it. Check native resolution and landscape, left, and right orientation. Scan the QR at room distance, first while signed out and again with an existing portal session. Both should reach Home, with sign-in when required.
   On Pi 4B and Pi 5, connect both monitors. Test `0` and `1` in turn, restarting the service each time. Check that only the selected monitor shows the kiosk. Unplug it, trigger a welcome, and reconnect it. Check stderr and the configured log for the cable warning and recovery on the same port. Verify that a welcome never appears on the other monitor. Repeat standby and wake on each socket.
2. Compare the PN532 UID against a known door scan through the resulting first-name welcome. Hold the card steady, remove and retap, then dismiss. Repeat starting at the door. Test a second member just before and after the 30-second handoff. Check that a local tap leaves door history unchanged.
   With location patterns configured, try an included and an excluded door. Both should update the member's single **Recent check-ins** entry. Only the included door should open the welcome. Check the log for the excluded location. At the included door, send a name-only check-in and then a fuller record of the same tap containing the UID of an active test fob. Confirm the large first name appears before the UID arrives and the agenda follows as soon as the card and member are verified. Repeat with two test members who share a first name and confirm each fob opens its owner’s agenda. With private details open, confirm a name-only arrival leaves that view in place.
3. Verify the first frame with a warm directory and slow agenda reads. Check that a long first name fits the welcome screen in both landscape and portrait, then shrinks into the header as the agenda loads. Repeat with a member who has no reservations. The **Welcome frame submitted** log duration measures scan recognition to frame submission. Target 500 ms or less on the awake screen. Measure the monitor's physical wake delay separately.
4. Check a participant's current private avatar, rank-icon fallback, DM-only delivered kudos, and a checkout expiring today. Exercise I²C, UART and reader-absent boots. Verify a door welcome in MQTT-only mode. Interrupt MongoDB and MQTT individually, check the reported errors, and restore each service. Verify that revoked cards and expired memberships stop opening personal pages.
5. Leave both inputs idle. Inspect the generic board after two minutes and monitor standby after four hours. Wake from standby independently with each input.
6. On a commissioning kiosk, set `WELCOMEPI_LAYOUT_INTERVAL_MINUTES=1` and `WELCOMEPI_DIM_AFTER_MINUTES=1` in `/etc/welcomepi.env` and restart `welcomepi.service`. On the awake public board watch the QR visit each corner, compare the light and dark layouts, and scan the QR at room distance on the dim board. Use eligible test taps to revisit the greeting, agenda and private details in both orientations. Check that the layout changes across visits, stays at normal brightness while reading, and preserves the required rows across the eight-second page cycle.
7. Let the board dim again between trials. Try a fresh check-in from a history-only door, then a new local presentation of an unrecognized fob. Each should brighten the same page. Repeat with an eligible fob and confirm that the greeting appears at normal brightness. A held fob and replayed arrivals should allow the board to dim. Restore the installation's chosen values and restart the service after the check.

The [wiki release patch](wiki-release.patch) updates **Check-In Activity** and **Troubleshooting** and adds **WelcomePi updates** for kiosk operators. Release these pages once the entrance display runs the version with layout cycling and dimming and its updater is deployed. In a current WikiPages checkout, fetch `master`, apply the patch on a branch with `git apply --check` then `git apply`, and open the normal wiki pull request.
