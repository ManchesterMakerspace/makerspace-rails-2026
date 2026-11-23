# Bring up WelcomePi on a Pi Zero W at 720p

Use the original Raspberry Pi Zero W, Raspberry Pi OS Lite **Bookworm 32-bit**, a PN532 in I²C (IIC) or UART mode, and an HDMI monitor that accepts **1280×720 at 60 Hz**. Allow access from the Pi's network to your existing MongoDB databases and MQTT broker. Have a consenting member with a working door fob available for the two acceptance checks. You can also run the display from door check-ins alone.

| Where | What to run |
| --- | --- |
| Workstation with the Rails checkout | Raspberry Pi Imager, then [workstation/setup.sh](workstation/setup.sh) to copy the kiosk files over SSH. |
| Pi Zero W | [setup.sh](setup.sh) installs the software, builds the virtual environment and configures the next boot. It also checks the installation, observes a real MQTT arrival, and enrolls a working kiosk for automatic updates. |

## 1. Flash the microSD card on the workstation

1. Install **Raspberry Pi Imager**. The transfer script needs Bash, OpenSSH and tar. On Windows, use **Git Bash** from Git for Windows. On macOS or Linux, use a terminal with those commands available. Check with `bash --version`, `ssh -V` and `tar --version`. [Raspberry Pi Imager](https://www.raspberrypi.com/software/) · [Git for Windows](https://gitforwindows.org/)
2. Insert a microSD card. A 16 GB card gives the OS, virtual environment and package updates room. In Imager select the **Zero W** or Zero family, then **Raspberry Pi OS (Legacy, 32-bit) Lite**. Confirm the description says **Debian 12 (Bookworm)** and **no desktop**. If Imager lists a different Debian release, download the official **32-bit Bookworm Lite** `.img.xz` and select **Use custom**. [Official OS images](https://www.raspberrypi.com/software/operating-systems/)
3. In OS customisation, use hostname **welcomepi**, create the operator login **makeradmin**, and set a password. Enable SSH and select your public key or password authentication. Reserve the separate username `welcomepi` for the installed service. Configure your **2.4 GHz** Wi-Fi SSID and password, the correct wireless country, and timezone **America/New_York**. Substitute your chosen operator name and hostname in the commands below. [Imager setup](https://www.raspberrypi.com/documentation/computers/getting-started.html) · [Zero W networking](https://www.raspberrypi.com/documentation/computers/zero.html)
4. Select the microSD by **capacity and device name**. Writing erases that card. Write the image, let Imager verify it, and eject it.

## 2. Wire the PN532 while power is disconnected

Set the breakout's switches or jumpers to **I²C** or **HSU / UART** using the markings for that exact board. Wire only the chosen interface. Use a soldered GPIO header on the Zero W. Pin numbers below are **physical header pins**.

| Pi Zero W | PN532 breakout | Connection |
| --- | --- | --- |
| Pin 6, GND | GND | Common ground |
| Pin 3, GPIO2 / SDA | SDA | I²C data |
| Pin 5, GPIO3 / SCL | SCL | I²C clock |
| Pin 8, GPIO14 / TXD | RX / RXD | UART, Pi transmits to reader |
| Pin 10, GPIO15 / RXD | TX / TXD | UART, reader transmits to Pi |
| Pin 1, 3V3 | 3.3 V supply input | Use this connection only on a breakout rated for 3.3 V supply and within the Pi's supply budget. |

Use **3.3 V logic** for both interfaces, including any SDA/SCL pull-ups. If the breakout specifies a different VIN, follow its manual for power and level shifting. Connect the monitor to the Zero's **mini HDMI** socket, select that input, insert the microSD, then connect the regulated 5 V supply to the micro-USB port marked **PWR IN**. [Pi GPIO specifications](https://www.raspberrypi.com/documentation/computers/raspberry-pi.html#gpio) · [Zero W ports and header](https://www.raspberrypi.com/documentation/computers/zero.html)

## 3. Copy the kiosk from the workstation

Let the first boot finish. From the workstation, connect once to confirm the SSH login. If `.local` does not resolve, substitute the Pi's DHCP address in both commands.

```sh
ssh makeradmin@welcomepi.local
```

At the Pi prompt, run `cat /proc/device-tree/model; echo`, `grep VERSION_CODENAME /etc/os-release` and `dpkg --print-architecture`. Expect **Raspberry Pi Zero W**, **bookworm** and **armhf**. Run `exit` to return to the workstation.

From the **makerspace-rails-2026 checkout containing this guide**, run the transfer. It places the deployable sources, scripts and example configuration in the operator's `~/WelcomePi` on the Pi. You can repeat it to send an updated checkout.

```sh
cd tools/WelcomePi
bash workstation/setup.sh makeradmin@welcomepi.local
ssh makeradmin@welcomepi.local
```

## 4. Install on the Pi

At the **Pi's SSH prompt**, start the installer.

```sh
cd ~/WelcomePi
sudo bash setup.sh install
```

The installer installs the full KMS bindings and `kmsprint`, Pillow, PyMongo and DNS support, Paho MQTT, QR generation, I²C tools, serial and USB libraries, fonts, CA certificates, time-zone data and Python venv support. It creates the service account, installs the unit with I²C and UART access, and creates a mode-0600 `/etc/welcomepi.env` on first install. MongoDB, ChangeStream2MQTT and the broker run on their existing hosts.

**For an I²C reader**, run `sudo raspi-config nonint do_i2c 0` before the reboot in step 5. After reboot the default header bus appears as `/dev/i2c-1`. WelcomePi gets the chip's firmware identity at Linux address `0x24`. Some breakout manuals print the equivalent wire bytes `0x48` (write) and `0x49` (read). Linux configuration takes the 7-bit address. A UART-only or door-only installation can leave I²C disabled. [Raspberry Pi interface settings](https://www.raspberrypi.com/documentation/computers/configuration.html#i2c) · [NXP PN532 manual](https://www.nxp.com/docs/en/user-guide/141520.pdf)

These are the virtual environment and dependency installation commands the installer runs from the staged source directory.

```sh
sudo /usr/bin/python3 -m venv --system-site-packages /opt/welcomepi/.venv
sudo /opt/welcomepi/.venv/bin/python -m pip install -r requirements.txt
```

The venv inherits the Pi distribution's **python3-pil** (Pillow) and **python3-kms++** (pykms). Pip installs the remaining requirements, including **nfcpy 1.0.4**. The installer prints the imported Pillow version. You can confirm which interpreter and Pillow version the service uses with the following command.

```sh
/opt/welcomepi/.venv/bin/python -c 'import sys, PIL, pykms, nfc; print(sys.prefix, PIL.__version__)'
```

For the next boot, the installer enables the GPIO UART and full KMS, gives HDMI mode selection to the kernel, removes the GPIO serial login console and sets `video=HDMI-A-1:1280x720@60 consoleblank=0`. It keeps the first copies of `config.txt` and `cmdline.txt` beside the originals in `/boot/firmware`, with suffix `.welcomepi-backup`. On a stock Zero W, `enable_uart=1` stabilizes the mini UART clock and Bluetooth keeps its existing assignment. [KMS display mode](https://www.raspberrypi.com/documentation/computers/configuration.html#set-the-kms-display-mode) · [Primary UART configuration](https://www.raspberrypi.com/documentation/computers/configuration.html#configure-uarts)

## 5. Configure the site connections and reboot

```sh
sudoedit /etc/welcomepi.env
```

Replace the sample hostnames and every `REPLACE` value with site-provisioned settings. Enter secrets in the editor. The file is read by systemd and can contain characters with special meaning to an interactive shell.

| Setting | What to supply |
| --- | --- |
| `MLAB_URI` | Read-only Rails MongoDB URI. Include the database watched by ChangeStream2MQTT in the URI path, commonly `/makerauth`. |
| `LEDGER_URI` | Read-only MongoDB URI with the actual Ledger database in its path. Include the correct `authSource` and TLS options where required in each URI. Percent-encode reserved characters in URI usernames and passwords. |
| `MQTT_HOST`, `MQTT_PORT`, `MQTT_TLS`, `MQTT_USERNAME`, `MQTT_PASSWORD` | Broker and subscribe-only credentials for this Pi. The example uses TLS on port 8883. The OS trust store must trust the broker's certificate. |
| `WELCOMEPI_NFC_PORT`, `WELCOMEPI_ROTATION` | Use `/dev/serial0` and `auto` for the initial setup. If the pixels need rotating for the physical mount, choose `left` or `right`. |
| `WELCOMEPI_I2C_BUS`, `WELCOMEPI_I2C_ADDRESSES` | Defaults to `/dev/i2c-1` and `0x24`. For an address translator, enter its documented 7-bit addresses in probe order, separated by commas. |
| `WELCOMEPI_SYSLOG_HOST`, `WELCOMEPI_SYSLOG_PORT` | Leave both unset for local syslog. For direct UDP delivery set both, for example `WELCOMEPI_SYSLOG_HOST=192.0.2.10` and `WELCOMEPI_SYSLOG_PORT=514`. Substitute your collector's IPv4 or IPv6 address and listening UDP port. |
| `EVENTBRITE_ORGANIZATION_IDS`, `SLACKIDS_INELIGIBLE`, `WELCOMEPI_SLACK_TOKEN` | Match the site's Eventbrite organizations and Ledger exclusions. The optional Slack token enables private avatar images when it has access to the Ledger DM file. |

Give the kiosk MongoDB **find** access on the collections in the [access table](README.md#configuration-and-access). Allow MQTT subscriptions to **checkins/insert** and to **insert**, **update**, **replace** and **delete** under both **members/** and **cards/**. The kiosk and the diagnostic use subscribe-only credentials. The diagnostic uses a separate client ID beginning with `wpi-check-` so it can run alongside the display. If broker policy binds credentials to one client ID, verify the live kiosk with the actual door scan and its journal.

```sh
sudo reboot
```

## 6. Check the hardware and start the generic board

Reconnect from the workstation with `ssh makeradmin@welcomepi.local`. Check the clock, available interfaces, display and connections before starting the service.

```sh
cd ~/WelcomePi
timedatectl status
i2cdetect -l
readlink -f /dev/serial0
cat /sys/class/drm/card*-HDMI-A-1/status
kmsprint
sudo bash setup.sh check
```

Look for a synchronized clock, **connected**, and an active **1280×720** mode. If `kmsprint` reports permission denied, run `sudo kmsprint`. The check prints the provisioned reader, for example `local PN532 I2C /dev/i2c-1@0x24` or `local PN532 UART /dev/serial0`. If both probes fail it reports **No PN532 found. Running MQTT-only** and continues checking the Rails and Ledger reads and all nine MQTT subscriptions. While the kiosk is running it owns the reader. Verify it with the local tap in step 7.

```sh
sudo systemctl enable --now welcomepi.service
sudo systemctl status welcomepi.service --no-pager
sudo journalctl -b -t welcomepi -f
```

The monitor should show today's date, the public board and the portal QR. Look for **HDMI HDMI-A-1: 1280x720** with the detected rotation and the PN532 provisioning result. With remote syslog selected, follow the receiver's `welcomepi` records for this Pi. The application sends directly to that collector, without a local application log or a flash spool. UDP delivery is best effort. Use a second SSH session for the MQTT check below.

## 7. Verify each first welcome

Use a fob with one active card record linked to an unmerged **activeMember** whose `expirationTime` is in the future. Start each test on the **generic board** so a same-member arrival is visibly a first welcome.

1. **Local PN532.** Starting at the generic board, present the fob to the kiosk reader. Expect **Welcome, first name!**, active status and today's date, followed by the agenda. Hold the fob still briefly. The agenda should stay visible. Remove it. This local tap controls only the display. Look for **Welcome frame submitted in … ms** in the selected log. The warm-cache target is 500 ms from recognition to frame submission. The time for a sleeping monitor to light up is a separate measurement.
2. **Return to the generic board.** Allow two minutes without eligible arrivals. To clear it sooner with a test member's consent, lift and present the same fob twice more on the local reader, removing it between presentations. The first opens shared-screen details, which can include private kudos. The second clears them.
3. **Real door check-in via MQTT.** In the second SSH session run the following. Wait for **Listening** before presenting the fob at the **door reader**. Leave the kiosk reader untouched.

```sh
cd ~/WelcomePi
sudo bash setup.sh watch-door
```

The observer should report **Received a fresh checkins/insert**, and the kiosk should show the matching first-name welcome. In the selected log, confirm an **INFO** record with the member's name and the local I²C/UART interface for the first tap, and another with `MQTT checkins/insert` and the reported door for the second. A held fob or redelivered check-in produces one scan entry. An unrecognized fob produces an **INFO** scan and a **WARNING**. Broker and database failures appear at **ERROR** with the driver reason. The observer prints only receipt and subscription results.

## 8. Enable automatic updates from master

Complete both welcome checks first. For an existing kiosk, use the workstation transfer in step 3 once to bring over the current setup scripts. The hosted **Publish WelcomePi** workflow must be on `master` in `ManchesterMakerspace/makerspace-rails-2026`. In GitHub, open **Actions → Publish WelcomePi** and check for a successful publication. **Run workflow** on **master** also performs the first publication or retries a failed run. The publishing job needs `contents: write` and permission under the repository's rules to advance `welcomepi-deploy`. Treat write access to that branch as permission to distribute kiosk code. [Publishing workflow](../../.github/workflows/publish-welcomepi.yml)

The original Zero W uses ARMv6. GitHub runs the tests and packages the release. The kiosk reads the public release over outbound HTTPS to `api.github.com` and `raw.githubusercontent.com`. A dependency change also needs access to the Pi's configured Python package index. The Pi needs no GitHub login, Actions runner, or inbound deployment port. [Zero W hardware](https://www.raspberrypi.com/documentation/computers/zero.html) · [.NET hardware support](https://learn.microsoft.com/en-us/dotnet/iot/intro)

From the **Pi's SSH prompt**, enroll the kiosk and inspect its first check.

```sh
cd ~/WelcomePi
sudo bash setup.sh enable-updates
systemctl list-timers welcomepi-update.timer
sudo systemctl start welcomepi-update.service
readlink /opt/welcomepi/current
systemctl show welcomepi.service -p InvocationID
sudo journalctl -b -u welcomepi-update.service --no-pager
```

Enrollment saves the installed code as the first rollback copy, adopts the existing virtual environment and enables a timer. The first poll after boot runs at about two minutes, then about five minutes after each check finishes. Starting the update service checks immediately. An unchanged release should leave both the `readlink` result and the kiosk's `InvocationID` unchanged, including on repeated checks. Diagnostics in steps 6 and 7 follow the active release.

| Change reaching master | Expected result |
| --- | --- |
| Rails-only edit | The push skips the WelcomePi workflow. |
| Kiosk guide, tests, installer or unit only | The workflow compares runtime files and leaves the published release alone. Apply host provisioning changes during maintenance. |
| Kiosk Python package or `pi0/check.py` | GitHub tests the runtime and publishes a new checksum. The Pi verifies the archive, reuses its venv, and restarts the display once. The generic board returns on startup. |
| `requirements.txt` | The Pi builds a separate native venv as the unprivileged `welcomepi-build` account. The working venv stays available during the build. After activation, repeat the local tap and door check. |

GitHub publishes only the runtime ZIP and manifest, together in one commit. A daily comparison at 05:17 UTC also picks up changes from very large merges that can exceed GitHub's path-filter limits. The Pi fetches both files by that immutable commit. Normal polls keep their HTTP cache in `/run`. The archive is verified in memory, unchanged files are hard-linked, and the Pi retains the current and previous managed releases. The original installer venv remains at its commissioning path. The updater holds a lock shared with the installer and leaves a deliberately stopped display in maintenance.

### Recovery and maintenance

- A network or checksum failure leaves the current service running for the next check. If Python dependency installation fails, the Pi waits an hour before retrying that revision. A newer revision can proceed on the next poll.
- Failed imports hold the candidate before activation. If the restarted kiosk fails its 12-second startup check, the updater selects the previous release, restarts it and holds the failed revision. An interrupted switch also restores the last working release on the next check, even offline.
- Inspect `sudo journalctl -b -u welcomepi-update.service -u welcomepi.service`. The Pi picks up a corrected release on `master` automatically. To retry the same held revision **after repairing its cause**, clear its retry records and start a check.

  ```sh
  sudo flock /run/lock/welcomepi-setup.lock rm -f /opt/welcomepi/update-rejected.json /run/welcomepi-update/dependency-retry.json
  sudo systemctl start welcomepi-update.service
  ```

- Pause future checks with `sudo systemctl disable --now welcomepi-update.timer`. Let an in-progress update finish. To maintain OS packages, boot settings, units or the updater itself, transfer the current scripts using step 3 and run `sudo bash setup.sh install`. On an enrolled kiosk this refreshes the host components and preserves the selected runtime. Reboot for boot changes. Resume with `sudo systemctl enable --now welcomepi-update.timer`.

### Optional RAM journal for a dedicated kiosk

Bookworm can keep the **whole host's journal** in RAM, including systemd's routine timer messages. Entries in this journal disappear at reboot. Enable this only if that retention suits the site. [Bookworm journald settings](https://manpages.debian.org/bookworm/systemd/journald.conf.5.en.html)

```sh
sudo install -d -m 0755 /etc/systemd/journald.conf.d
printf '[Journal]\nStorage=volatile\nRuntimeMaxUse=8M\n' | sudo tee /etc/systemd/journald.conf.d/60-welcomepi-volatile.conf >/dev/null
sudo systemctl restart systemd-journald
```

To return to the host's previous policy, remove that drop-in and restart `systemd-journald`.

## If a check fails

| Symptom | What to check |
| --- | --- |
| Cannot reach the Pi | Check power at PWR IN, the 2.4 GHz SSID, wireless country, SSH settings and the DHCP lease. |
| Package or Python import fails | Confirm `bookworm` and `armhf`. Check package availability with `apt-cache policy python3-kms++ python3-pil` and confirm the venv interpreter under `/opt/welcomepi` is in use. Fix the package source or network and rerun `install`. |
| Blank HDMI or wrong mode | Connect the powered monitor and select its input. Check `kmsprint`, the journal, and `grep -o 'video=HDMI-A-1:[^ ]*' /proc/cmdline`. The live kernel should report the 720p setting after reboot. For boot recovery, the workstation can copy the two `.welcomepi-backup` files back over their respective originals on the microSD boot partition. |
| I²C reader falls back to UART or MQTT-only | Check the breakout's mode and power, 3.3 V SDA/SCL wiring, `i2cdetect -l`, and `ls -l /dev/i2c-1`. On an existing installation, repeat steps 3 and 4 to install the updated service group permissions. A PN532 can stretch SCL during wake-up. If the hardware adapter times out, the serial fallback or a Linux `i2c-gpio` adapter on separate pins can be used. Set `WELCOMEPI_I2C_BUS` to the resulting device. [PN532 I²C driver](https://github.com/nfc-tools/libnfc/blob/master/libnfc/drivers/pn532_i2c.c) · [Pi overlay parameters](https://github.com/raspberrypi/firmware/blob/master/boot/overlays/README) |
| UART reader fails or the fob does nothing | Check power, common ground, crossed TX/RX, HSU mode and `readlink -f /dev/serial0`. A UART listed in `/proc/consoles` is still a kernel console. For either transport, stop `welcomepi`, run `sudo bash setup.sh check`, then restart the service. If the handshake works, check the scan warning and member eligibility. [nfcpy serial reader setup](https://nfcpy.readthedocs.io/en/latest/topics/get-started.html) |
| No application logs on the remote collector | Check that both syslog settings are present, the address belongs to the collector, its UDP input is enabled, and its firewall accepts the configured port from the Pi. Restart `welcomepi` and look for the PN532 provisioning record at the collector. Remove both settings and restart to restore local app logging. |
| Database read fails | Check the database name in each URI, credentials, `authSource`, DNS, network access and CA trust on the Pi. The diagnostic names the failed read and omits the URI. |
| Local works but the door does not | Check the Pi's clock, TLS and broker ACLs, then wait for a new door entry with `watch-door`. A fresh, non-retained `checkins/insert` must come from ChangeStream2MQTT. Old records and redeliveries do not wake the kiosk. If the observer succeeds but the kiosk stays on the board, check eligibility, the kiosk's own broker client ID and its service journal. |

After editing `/etc/welcomepi.env`, run `sudo systemctl restart welcomepi.service`. For manually managed kiosks, repeat the workstation copy and Pi install for an update. The installer keeps the configured environment and the original boot backups, and restarts a previously running instance. Reboot to activate any new boot settings.
