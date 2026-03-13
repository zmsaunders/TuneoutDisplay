# TuneoutDisplay

A countertop smart display built on Raspberry Pi with a Home Assistant kiosk, always-on wake word detection, voice pipeline, Music Assistant playback, and full HA device integration via MQTT.

## Full Disclosure

This is a project I work on in the evenings, and the initial build and scripting was created in conjunction with Claude AI. I make no guarantees or warranties, and suggest you read through the code base if you aren't comfortable executing code written by an AI agent. I've made every effort to review it and guide it, but as a side project my biggest concern was having something functional and re-usable. I am 100% open to any pull requests or changes anyone wants to submit.

---

## Hardware

| Component | Details |
|---|---|
| SBC | Raspberry Pi 4B (2 GB RAM) |
| Microphone / Audio | KEYESTUDIO ReSpeaker 2-Mic Pi HAT (WM8960 codec) |
| Display | Raspberry Pi Official 7" DSI Touchscreen |
| Speaker | 3W 8Ω |
| OS | Raspberry Pi OS 64-bit (Trixie / Debian 13), kernel 6.12.x |
| Compositor | labwc (Wayland) |

---

## Features

- **HA Lovelace kiosk** — Chromium in kiosk mode, launches automatically after boot and waits for HA to be reachable before opening
- **Wake word detection** — Wyoming openWakeWord (`hey_jarvis` by default, configurable)
- **Voice pipeline** — Wyoming Satellite connects to HA's Assist pipeline; ALC is toggled during STT to prevent the mic from staying open
- **Music Assistant playback** — Sendspin native player; appears automatically in MA 2.7+
- **MQTT auto-discovery** — Device registers itself in HA with Voice Volume, Media Volume, Brightness, and Stop TTS entities — no YAML needed
- **Touch scrolling** — Daemon translates touchscreen swipe gestures into scroll-wheel events for labwc/Wayland
- **Independent volume channels** — TTS/voice and media are separate ALSA softvol streams, each with its own HA slider

---

## Repo Structure

```
configure.sh              # Main setup script — run once on a fresh install
stop-server.py            # Lightweight HTTP server (port 12345) for stopping TTS
mqtt-bridge.py            # MQTT auto-discovery bridge for HA device entities
touch-scroll.py           # Touch-to-scroll daemon (uinput virtual device)
lovelace/
  smart-display-card.js   # Custom Lovelace card (copy to HA /config/www/)
```

---

## Setup

### Prerequisites

- Fresh **Raspberry Pi OS 64-bit (Trixie)** install
- Pi connected to your network
- Home Assistant running with:
  - **Wyoming Protocol** integration installed
  - **MQTT integration** (Mosquitto) installed and configured
  - **Music Assistant 2.7+** (optional, for Sendspin)

### 1. Run the configuration script

Clone this repo onto the Pi and run the setup script as your normal user (not root):

```bash
git clone https://github.com/YOUR_USERNAME/TuneoutDisplay.git
cd TuneoutDisplay
chmod +x configure.sh
./configure.sh
```

The script will prompt you for:
- Device name (used as the HA device name and Music Assistant player name)
- Home Assistant URL
- Wake word model name
- Lovelace kiosk URL (optional — skip to set up kiosk manually later)
- MQTT broker host, port, username, and password

It then installs and configures everything automatically and offers to reboot when done.

### 2. Add the Wyoming satellite to Home Assistant

After reboot, in HA go to:

**Settings → Devices & Services → Add Integration → Wyoming Protocol**

| Field | Value |
|---|---|
| Host | `<hostname>.local` |
| Port | `10700` |

### 3. Verify MQTT device

In HA go to **Settings → Devices & Services → MQTT** and look for your device name. It should appear automatically with four entities:

- Voice Volume (number)
- Media Volume (number)
- Brightness (number)
- Stop TTS (button)

If it doesn't appear, check that MQTT discovery is enabled in the MQTT integration settings.

### 4. Add the Lovelace control card (optional)

The custom card gives you volume, brightness, and voice status controls in any HA dashboard.

1. Copy `lovelace/smart-display-card.js` to `/config/www/` on your HA instance
2. In HA go to **Settings → Dashboards → ⋮ → Resources → Add**
   - URL: `/local/smart-display-card.js`
   - Type: JavaScript module
3. Add the card to a dashboard:

```yaml
type: custom:smart-display-card
name: TuneoutDisplay
satellite_entity: assist_satellite.YOUR_SATELLITE_ENTITY
tts_volume_entity: number.YOUR_DEVICE_tts_volume
media_volume_entity: number.YOUR_DEVICE_media_volume
brightness_entity: number.YOUR_DEVICE_brightness
stop_entity: button.YOUR_DEVICE_stop_tts
```

Find your exact entity IDs under **Developer Tools → States** and search for your device name.

### 5. Add swipe navigation between dashboard views (optional)

Install **Swipe Navigation** from HACS (Frontend section), then add `/hacsfiles/swipe-navigation/swipe-navigation.js` as a Lovelace resource. No card config needed — it activates automatically on all views.

---

## Services

All services are managed by systemd and start automatically on boot.

| Service | Description |
|---|---|
| `wyoming-openwakeword` | Listens for wake word on port 10400 |
| `wyoming-satellite` | Voice pipeline satellite on port 10700 |
| `sendspin` | Music Assistant native player |
| `smart-display-audio-init` | Restores ALSA mixer state after seeed DKMS module loads |
| `smart-display-stop` | HTTP server on port 12345 (`/stop`, `/tts-volume`, `/media-volume`, `/brightness`) |
| `smart-display-mqtt` | MQTT bridge for HA auto-discovery |
| `smart-display-touch-scroll` | Translates touchscreen swipe gestures into scroll-wheel events |

Check all service status:
```bash
sudo systemctl status wyoming-openwakeword wyoming-satellite sendspin \
  smart-display-audio-init smart-display-stop smart-display-mqtt smart-display-touch-scroll
```

Follow live voice pipeline logs:
```bash
journalctl -u wyoming-satellite -f
```

---

## Audio Architecture

```
Hardware: WM8960 (seeed2micvoicec)
           │
           ▼
      seeed_dmix         ← ALSA dmix (allows multiple simultaneous writers)
           │
      seeed_shared       ← plug over dmix (general use)
         ┌─┴─┐
   seeed_tts  seeed_media     ← softvol streams (independent volume controls)
       │           │
  Wyoming TTS   Sendspin
  (voice/TTS)   (music)
```

Volume controls:
- **TTS Volume** — `amixer -c seeed2micvoicec cset "name=TTS Volume" 80%`
- **Media Volume** — `amixer -c seeed2micvoicec cset "name=Media Volume" 80%`

---

## Customisation

### Wake word

Change the wake word by editing `wyoming-openwakeword.service` and `wyoming-satellite.service` and replacing `hey_jarvis` with any model supported by openWakeWord (e.g. `ok_nabu`, `hey_mycroft`).

### Touch scroll speed

Edit `/usr/local/bin/touch-scroll.py` and adjust `TICKS_PER_SCREEN` (higher = faster scroll), then restart the service:

```bash
sudo systemctl restart smart-display-touch-scroll
```

### Kiosk URL

Edit `~/.config/labwc/autostart` to change the URL Chromium opens on boot.

---

## Troubleshooting

**Audio settings don't persist after reboot**
The seeed DKMS module loads after `alsa-restore` runs. The `smart-display-audio-init` service handles this — check its status and logs.

**Voice pipeline stays in "Listening" state**
ALC (Automatic Level Control) holds the mic level up, preventing HA from detecting end-of-speech. The ALC toggle via `--stt-start-command` / `--stt-stop-command` in the satellite service fixes this.

**MQTT entities don't appear in HA**
- Check credentials in `/etc/smart-display/mqtt.env`
- Verify MQTT discovery is enabled in HA's MQTT integration settings
- Check `journalctl -u smart-display-mqtt -f` for connection errors

**Touch scrolling not working**
Check the daemon is running: `systemctl status smart-display-touch-scroll`
View logs: `journalctl -u smart-display-touch-scroll -f`


# License

> This project is licensed under the terms of the GNU General Public License v3.0. See the LICENSE.txt file for details.