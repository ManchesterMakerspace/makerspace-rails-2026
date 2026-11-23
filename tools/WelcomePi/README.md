# WelcomePi

WelcomePi is a read-only entrance kiosk for Raspberry Pi OS Lite **Bookworm, 32-bit**. It draws directly to HDMI with Pillow and KMS. A successful door check-in or a tap on the local PN532 wakes the display and greets a member. Local taps only control this screen.

For a **Pi Zero W at 720p**, follow the [step-by-step setup guide](setup-pi0.MD). It includes the workstation transfer, GPIO wiring, Pi installer, and separate first-welcome checks at the kiosk and the door.

## Choosing an older board

| Board on hand | Fit for the kiosk |
| --- | --- |
| Pi Zero W, 512 MB | First choice for a low-power installation. Its 1 GHz single-core ARM11 and memory match the original Zero target, and it has 2.4 GHz Wi-Fi. Use mini HDMI and a populated GPIO header for the PN532. [Zero specifications](https://www.raspberrypi.com/documentation/computers/zero.html) |
| Pi 1, 512 MB | Oldest candidate to try. A later 2012 Model B or a Model B+ has a 700 MHz single-core ARM11 and built-in Ethernet. Start at 1280×720 and measure the greeting on that board. Some Pi 1 revisions have only 256 MB. Look up the value from `grep '^Revision' /proc/cpuinfo` before choosing one. [Board specifications](https://www.raspberrypi.com/documentation/computers/sbcs.html) · [Revision table](https://www.raspberrypi.com/documentation/computers/raspberry-pi.html#raspberry-pi-revision-codes) |
| Pi 2 Model B, 1 GB | Wired option with four CPU cores and more room for a 1080p portrait display. [Board specifications](https://www.raspberrypi.com/documentation/computers/sbcs.html) |

Select **Raspberry Pi OS (Legacy, 32-bit) Lite**, Debian 12 Bookworm. The official download lists Zero W, 1B+, and 2B for this image. The earliest 256 MB Pi 1 boards are experimental for this kiosk. At 720p the two HDMI buffers occupy about 7 MiB, rising to 16 MiB at 1080p, before Pillow's working images, Python, the member cache, and the OS. The 500 ms greeting target and monitor wake behavior require on-device measurement. [Raspberry Pi OS downloads](https://www.raspberrypi.com/software/operating-systems/)

## Install on a Pi Zero or Pi 3B+

1. Connect the HDMI monitor and provide networking. An original Zero needs a network adapter. Set the PN532 module to **HSU/UART** mode according to its board markings. Cross its **3.3 V logic** TX/RX with Pi GPIO15/RXD (pin 10) and GPIO14/TXD (pin 8), connect ground, and power the breakout according to its own specifications. The original Zero may need a soldered GPIO header.
2. In `sudo raspi-config` → **Interface Options** → **Serial Port**, disable the serial login shell and enable the serial hardware. Reboot and check `readlink -f /dev/serial0`. A USB-to-UART adapter can use its stable `/dev/serial/by-id/...` path instead. WelcomePi discovers an ISO 14443-A UID with nfcpy and preserves byte order and leading zeroes. [nfcpy serial configuration](https://nfcpy.readthedocs.io/en/latest/topics/get-started.html)
3. Use the full `vc4-kms-v3d` graphics driver and dedicate the HDMI output to the kiosk. Check the connected display with `kmsprint`. Keep console blanking disabled (`consoleblank=0` on the existing single kernel command line in `/boot/firmware/cmdline.txt`) so the kiosk owns the standby timer. Detect rotation automatically or set an override below. [Pi display configuration](https://www.raspberrypi.com/documentation/computers/configuration.html#set-the-kms-display-mode)
   To try 720p on a slower Pi with a compatible monitor, append `video=HDMI-A-1:1280x720@60` to the same line and reboot. Use the connector name reported by `kmsprint`.
4. From this tool directory in the checkout, install the system libraries and service. The virtual environment inherits the distribution's Pillow, MongoDB driver, and KMS bindings. This avoids depending on ARMv7 binary wheels on the ARMv6 Zero. [Raspberry Pi KMS Python bindings](https://github.com/raspberrypi/pykms)

```sh
sudo apt update
sudo apt install python3-venv python3-kms++ kms++-utils python3-pil python3-pymongo \
  python3-dnspython python3-paho-mqtt python3-qrcode python3-serial python3-usb1 \
  libusb-1.0-0 ca-certificates fonts-dejavu-core tzdata
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
journalctl -u welcomepi -f
```

For an upgrade, replace the code and dependencies under `/opt/welcomepi`, install the updated unit, run `systemctl daemon-reload`, and restart `welcomepi`. Keep the configured environment file. Stop the kiosk with `sudo systemctl stop welcomepi`.

## Configuration and access

Set values in `/etc/welcomepi.env`. Restart the service after edits.

| Variable | Use |
| --- | --- |
| `MLAB_URI`, `LEDGER_URI` | Required. Read-only MongoDB URIs including the Rails source and Ledger database names respectively. Use the source database watched by ChangeStream2MQTT, normally `makerauth`. |
| `MQTT_HOST`, `MQTT_PORT`, `MQTT_TLS` | Host required. TLS defaults to `true` with port 8883. Explicit `false` defaults to 1883. TLS verifies the broker against the OS trust store. |
| `MQTT_USERNAME`, `MQTT_PASSWORD`, `MQTT_CLIENT_ID` | Broker credentials if required. The default client ID is `welcomepi-<hostname>`. Give each kiosk a unique ID. |
| `WELCOMEPI_NFC_PORT` | Default `/dev/serial0`. Points to the PN532 serial device. |
| `WELCOMEPI_ROTATION` | `auto` uses the active plane, connector orientation, kernel display settings, or console rotation. `left` rotates the rendered image counterclockwise, `right` clockwise, and `normal` uses no rotation. A monitor without orientation metadata needs an override if mounted sideways. |
| `WELCOMEPI_OPPORTUNITIES` | Positive integer, default 5. The generic board lists up to 10. |
| `EVENTBRITE_ORGANIZATION_IDS` | Match Rails' comma-separated organization IDs. Empty permits all synced organizations. |
| `SLACKIDS_INELIGIBLE` | Match Ledger's Slack exclusions. Accepts a JSON list or its quoted brace-delimited set. Default empty. |
| `WELCOMEPI_SLACK_TOKEN` | Enables generated artwork. The credential on the Pi needs `files:read` **and access to the Ledger bot's private DM file**. An unrelated bot with the same scope cannot read that file. Without an accessible thumbnail, the character sheet uses a rank icon. [Slack file permissions](https://docs.slack.dev/reference/methods/files.info/) |

Grant MongoDB **find** access on these collections only. Aggregations use the same read privileges. WelcomePi writes no check-ins, claims, acknowledgments, or profile changes.

| Database | Collections |
| --- | --- |
| Rails | `members`, `cards`, `checkins`, `reservations`, `shops`, `tools`, `tool_checkouts`, `volunteer_tasks`, `volunteer_events`, `volunteer_credits`, `fix_tickets`, `eventbrite_events`, `slack_users` |
| Ledger | `ledger_participants`, `ledger_catalog`, `ledger_awards`, `ledger_evidence`, `ledger_avatars` |

Grant the kiosk subscribe-only access to `checkins/insert` and each of `insert`, `update`, `replace`, `delete` under `members/` and `cards/`. Only the trusted publisher should be able to publish on these topics. The existing publisher sends **full member documents**, including sensitive fields. WelcomePi projects identity fields before queuing an event and keeps the directory, personal text, and private image bytes in process memory. Its diagnostics contain component names, error types, display geometry, and greeting timing.

## Operation

- A unique active card linked to an unmerged, fully active member with a future expiration opens the agenda. The header can render from RAM while reservations, volunteering, and event listings load. Held reservations include pending and unpaid time. The day, weekday and checkout expiration use Manchester time.
- While the agenda is visible, lift and present the same member's fob locally to open their character sheet or received kudos and tool checkouts. **Everyone near the display can read the full kudos text, including DM-only messages.** Only recipient-delivered kudos appear. A third local tap clears the display.
- A different local fob takes over immediately. On a secondary page the newest other door arrival waits for at most the first 30 seconds after entry. A local dismissal cancels that handoff. Two idle minutes clear personal details. Four idle hours disable HDMI output while both listeners remain active.
- The generic board shows recorded arrivals, lifetime approved volunteer credits including signed reversals, and globally claimable work. Required rows rotate through pages every eight seconds if necessary. A phone can open the portal using the QR code. Check-in delivery, cache rebuilds, and page cycling never generate new door records.
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
2. Compare the PN532 UID against a known door scan through the resulting first-name welcome. Hold the card steady, remove and retap, then dismiss. Repeat starting at the door. Test a second member just before and after the 30-second handoff. Check that a local tap leaves door history unchanged.
3. Verify the first frame with a warm directory, slow agenda reads, and a sleeping monitor. The journal's **Welcome frame submitted** duration measures scan recognition to frame submission. Target 500 ms or less on the awake screen. Measure the monitor's physical wake delay separately.
4. Check a participant's current private avatar, rank-icon fallback, DM-only delivered kudos, and a checkout expiring today. Interrupt MongoDB, MQTT and the UART individually and restore each service. Verify that revoked cards and expired memberships stop opening personal pages.
5. Leave both inputs idle. Inspect the generic board after two minutes and monitor standby after four hours. Wake from standby independently with each input.

The [wiki release patch](wiki-release.patch) updates **Check-In Activity** and **Troubleshooting**. Hold it until the entrance display is deployed. In a current WikiPages checkout, fetch `master`, apply the patch on a branch with `git apply --check` then `git apply`, and open the normal wiki pull request.
