# Bring up WelcomePi on a Pi Zero W at 720p

Use the original Raspberry Pi Zero W, Raspberry Pi OS Lite **Bookworm 32-bit**, a PN532 in UART mode, and an HDMI monitor that accepts **1280×720 at 60 Hz**. Allow access from the Pi's network to your existing MongoDB databases and MQTT broker. Have a consenting member with a known working door fob available for the two acceptance checks.

| Where | What to run |
| --- | --- |
| Workstation with the Rails checkout | Raspberry Pi Imager, then [workstation/setup.sh](workstation/setup.sh) to copy the kiosk files over SSH. |
| Pi Zero W | [setup.sh](setup.sh) installs the software, builds the virtual environment and configures the next boot. The same script can check the installation and observe a real MQTT arrival. |

## 1. Flash the microSD card on the workstation

1. Install **Raspberry Pi Imager**. The transfer script needs Bash, OpenSSH and tar. On Windows, use **Git Bash** from Git for Windows. On macOS or Linux, use a terminal with those commands available. Check with `bash --version`, `ssh -V` and `tar --version`. [Raspberry Pi Imager](https://www.raspberrypi.com/software/) · [Git for Windows](https://gitforwindows.org/)
2. Insert a microSD card. A 16 GB card gives the OS, virtual environment and package updates room. In Imager select the **Zero W** or Zero family, then **Raspberry Pi OS (Legacy, 32-bit) Lite**. Confirm the description says **Debian 12 (Bookworm)** and **no desktop**. If Imager lists a different Debian release, download the official **32-bit Bookworm Lite** `.img.xz` and select **Use custom**. [Official OS images](https://www.raspberrypi.com/software/operating-systems/)
3. In OS customisation, use hostname **welcomepi**, create the operator login **makeradmin**, and set a password. Enable SSH and select your public key or password authentication. Reserve the separate username `welcomepi` for the installed service. Configure your **2.4 GHz** Wi-Fi SSID and password, the correct wireless country, and timezone **America/New_York**. Substitute your chosen operator name and hostname in the commands below. [Imager setup](https://www.raspberrypi.com/documentation/computers/getting-started.html) · [Zero W networking](https://www.raspberrypi.com/documentation/computers/zero.html)
4. Select the microSD by **capacity and device name**. Writing erases that card. Write the image, let Imager verify it, and eject it.

## 2. Wire the PN532 while power is disconnected

Set the breakout's switches or jumpers to **HSU / UART** using the markings or manual for that exact board. Switch positions vary. Use a soldered GPIO header on the Zero W. Pin numbers below are **physical header pins**.

| Pi Zero W | PN532 breakout | Connection |
| --- | --- | --- |
| Pin 6, GND | GND | Common ground |
| Pin 8, GPIO14 / TXD | RX / RXD | Pi transmits to reader |
| Pin 10, GPIO15 / RXD | TX / TXD | Reader transmits to Pi |
| Pin 1, 3V3 | 3.3 V supply input | Use this connection only on a breakout rated for 3.3 V supply and within the Pi's supply budget. |

Use **3.3 V logic** on both UART lines. If the breakout specifies a different VIN, power it according to its own manual and check its TX/RX logic levels. A 5 V UART output can damage the Pi's GPIO. Connect the monitor to the Zero's **mini HDMI** socket, select that input, insert the microSD, then connect the regulated 5 V supply to the micro-USB port marked **PWR IN**. [Pi UART electrical specifications](https://www.raspberrypi.com/documentation/computers/configuration.html#configure-uarts) · [Zero W ports and header](https://www.raspberrypi.com/documentation/computers/zero.html)

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

The installer uses `apt-get` for the full KMS bindings and `kmsprint`, Pillow, PyMongo and DNS support, Paho MQTT, QR generation, serial and USB libraries, fonts, CA certificates, time-zone data and Python venv support. It creates the service account, installs the code and unit, and creates a mode-0600 `/etc/welcomepi.env` on first install. MongoDB, ChangeStream2MQTT and the broker run on their existing hosts.

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
| `EVENTBRITE_ORGANIZATION_IDS`, `SLACKIDS_INELIGIBLE`, `WELCOMEPI_SLACK_TOKEN` | Match the site's Eventbrite organizations and Ledger exclusions. The optional Slack token enables private avatar images when it has access to the Ledger DM file. |

Give the kiosk MongoDB **find** access on the collections in the [access table](README.md#configuration-and-access). Allow MQTT subscriptions to **checkins/insert** and to **insert**, **update**, **replace** and **delete** under both **members/** and **cards/**. The kiosk and the diagnostic use subscribe-only credentials. The diagnostic uses a separate client ID beginning with `wpi-check-` so it can run alongside the display. If broker policy binds credentials to one client ID, verify the live kiosk with the actual door scan and its journal.

```sh
sudo reboot
```

## 6. Check the hardware and start the generic board

Reconnect from the workstation with `ssh makeradmin@welcomepi.local`. Check the clock, UART, display and connections before starting the service.

```sh
cd ~/WelcomePi
timedatectl status
readlink -f /dev/serial0
cat /sys/class/drm/card*-HDMI-A-1/status
kmsprint
sudo bash setup.sh check
```

Look for the correct local time and a synchronized system clock, a UART device such as `/dev/ttyS0` (or `/dev/ttyAMA0` if remapped), **connected**, and an active **1280×720** mode. If `kmsprint` reports permission denied in the SSH login, run `sudo kmsprint`. The check opens the PN532 and reads its firmware handshake, performs read-only queries against Rails and Ledger, and waits for broker acknowledgment of all nine subscriptions. Each check prints **OK** or **FAIL**. When the kiosk is already running, it keeps ownership of the UART and the check reports that the local tap is the reader test.

```sh
sudo systemctl enable --now welcomepi.service
sudo systemctl status welcomepi.service --no-pager
sudo journalctl -b -u welcomepi.service -f
```

The monitor should show today's date, the public board and the portal QR. The journal should contain **HDMI HDMI-A-1: 1280x720** with the detected rotation. Leave this SSH session following the journal. Use a second SSH session for the MQTT check below. **Ctrl+C** stops following the journal and leaves the service running.

## 7. Verify each first welcome

Use a fob with one active card record linked to an unmerged **activeMember** whose `expirationTime` is in the future. Start each test on the **generic board** so a same-member arrival is visibly a first welcome.

1. **Local PN532.** Starting at the generic board, present the fob to the kiosk reader. Expect **Welcome, first name!**, active status and today's date, followed by the agenda. Hold the fob still briefly. The agenda should stay visible. Remove it. This local tap controls only the display. Note the journal's **Welcome frame submitted in … ms**. The warm-cache target is 500 ms from recognition to frame submission. The time for a sleeping monitor to light up is a separate measurement.
2. **Return to the generic board.** Allow two minutes without eligible arrivals. To clear it sooner with a test member's consent, lift and present the same fob twice more on the local reader, removing it between presentations. The first opens shared-screen details, which can include private kudos. The second clears them.
3. **Real door check-in via MQTT.** In the second SSH session run the following. Wait for **Listening** before presenting the fob at the **door reader**. Leave the kiosk reader untouched.

```sh
cd ~/WelcomePi
sudo bash setup.sh watch-door
```

The observer should report **Received a fresh checkins/insert**, and the kiosk should show the matching first-name welcome. The journal should record a new frame submission. This exercises the door, its recorded check-in, ChangeStream2MQTT, the broker and the kiosk together. The observer uses a read-only subscription and prints only the subscription and receipt results. A later door arrival for a member whose agenda is already visible refreshes activity on that page.

## If a check fails

| Symptom | What to check |
| --- | --- |
| Cannot reach the Pi | Check power at PWR IN, the 2.4 GHz SSID, wireless country, SSH settings and the DHCP lease. |
| Package or Python import fails | Confirm `bookworm` and `armhf`. Check package availability with `apt-cache policy python3-kms++ python3-pil` and confirm the venv interpreter under `/opt/welcomepi` is in use. Fix the package source or network and rerun `install`. |
| Blank HDMI or wrong mode | Connect the powered monitor and select its input. Check `kmsprint`, the journal, and `grep -o 'video=HDMI-A-1:[^ ]*' /proc/cmdline`. The live kernel should report the 720p setting after reboot. For boot recovery, the workstation can copy the two `.welcomepi-backup` files back over their respective originals on the microSD boot partition. |
| PN532 fails or the fob does nothing | Check power, ground, crossed TX/RX, HSU selection and `readlink -f /dev/serial0`. A GPIO UART listed in `/proc/consoles` is still a kernel console. For a standalone reader handshake, run `sudo systemctl stop welcomepi`, `sudo bash setup.sh check`, then `sudo systemctl start welcomepi`. Verify card and member eligibility if the handshake succeeds. [nfcpy serial reader setup](https://nfcpy.readthedocs.io/en/latest/topics/get-started.html) |
| Database read fails | Check the database name in each URI, credentials, `authSource`, DNS, network access and CA trust on the Pi. The diagnostic names the failed read and omits the URI. |
| Local works but the door does not | Check the Pi's clock, TLS and broker ACLs, then wait for a new door entry with `watch-door`. A fresh, non-retained `checkins/insert` must come from ChangeStream2MQTT. Old records and redeliveries do not wake the kiosk. If the observer succeeds but the kiosk stays on the board, check eligibility, the kiosk's own broker client ID and its service journal. |

After editing `/etc/welcomepi.env`, run `sudo systemctl restart welcomepi.service`. For an update, repeat the workstation copy and Pi install. The installer keeps the configured environment and the original boot backups, and restarts a previously running instance. Reboot to activate any new boot settings.
