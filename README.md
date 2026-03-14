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
- **Wake word detection** — OpenWakeWord via Linux Voice Assistant (`hey_jarvis` by default, configurable)
- **Voice pipeline** — LVA connects to HA via the ESPHome integration; includes mute control directly from HA
- **Music Assistant playback** — Sendspin native player; appears automatically in MA 2.7+
- **MQTT auto-discovery** — Device registers itself in HA with Voice Volume, Media Volume, Brightness, and Mic Sensitivity entities — no YAML needed
- **Touch scrolling** — Daemon translates touchscreen swipe gestures into scroll-wheel events for labwc/Wayland
- **Independent volume channels** — TTS/voice and media are separate ALSA softvol streams, each with its own HA slider
- **Per-device mic tuning** — Mic sensitivity is adjustable from HA, persists across reboots, useful for different room sizes and placements

---

## Repo Structure

```
configure.sh              # Main setup script — run once on a fresh install (idempotent, re-runnable)
mqtt-bridge.py            # MQTT auto-discovery bridge for HA device entities
touch-scroll.py           # Touch-to-scroll daemon (uinput virtual device)
lovelace/
  smart-display-card.js   # Custom Lovelace card (copy to HA /config/www/)
ha-configuration.md       # Full HA config reference
CLAUDE.md                 # Technical reference for AI-assisted development
```

---

## Setup

### Prerequisites

- Fresh **Raspberry Pi OS 64-bit (Trixie)** install
- Pi connected to your network
- Home Assistant running with:
  - **ESPHome** integration installed
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

The script prompts you for:
- Device name (used as the HA device name and Music Assistant player name)
- Home Assistant URL
- Wake word model name
- Lovelace kiosk URL (optional — skip to set up kiosk manually later)
- MQTT broker host, port, username, and password

Settings are saved after the first run — re-running the script will pre-fill all prompts with your previous values, so you only need to change what's different.

The script installs and configures everything automatically, then offers to reboot when done.

### 2. Add the voice assistant to Home Assistant

After reboot, in HA go to:

**Settings → Devices & Services → Add Integration → ESPHome**

| Field | Value |
|---|---|
| Host | `<hostname>.local` |
| Port | `6053` |

Once added, open the device and click **"Set Up Voice Assistant"** to assign it to a voice pipeline (Whisper STT + Piper TTS recommended).

### 3. Verify MQTT device

In HA go to **Settings → Devices & Services → MQTT** and look for your device name. It should appear automatically with these entities:

- Voice Volume (number)
- Media Volume (number)
- Brightness (number)
- Mic Sensitivity (number)

If it doesn't appear, check that MQTT discovery is enabled in the MQTT integration settings.

### 4. Add the Lovelace control card (optional)

The custom card gives you volume, brightness, voice status, and a mute toggle in any HA dashboard.

1. Copy `lovelace/smart-display-card.js` to `/config/www/` on your HA instance
2. In HA go to **Settings → Dashboards → ⋮ → Resources → Add**
   - URL: `/local/smart-display-card.js`
   - Type: JavaScript module
3. Add the card to a dashboard:

```yaml
type: custom:smart-display-card
name: My Display
satellite_entity: assist_satellite.YOUR_DEVICE
tts_volume_entity: number.YOUR_DEVICE_tts_volume
media_volume_entity: number.YOUR_DEVICE_media_volume
brightness_entity: number.YOUR_DEVICE_brightness
mute_entity: switch.YOUR_DEVICE_mute        # optional — enables chip tap-to-mute
mic_gain_entity: number.YOUR_DEVICE_mic_gain  # optional
```

Find your exact entity IDs under **Developer Tools → States** and search for your device name.

The status chip in the card header shows the current pipeline state (Standby / Listening / Responding / Muted) and acts as a mute toggle when `mute_entity` is configured — tap to mute, tap again to unmute.

### 5. Add swipe navigation between dashboard views (optional)

Install **Swipe Navigation** from HACS (Frontend section), then add `/hacsfiles/swipe-navigation/swipe-navigation.js` as a Lovelace resource. No card config needed — it activates automatically on all views.

---

## Services

All services are managed by systemd and start automatically on boot.

| Service | Description |
|---|---|
| `linux-voice-assistant` | Wake word detection and voice pipeline (ESPHome protocol) |
| `sendspin` | Music Assistant native player |
| `smart-display-audio-init` | Restores ALSA mixer state after seeed DKMS module loads |
| `smart-display-mqtt` | MQTT bridge for HA auto-discovery |
| `smart-display-touch-scroll` | Translates touchscreen swipe gestures into scroll-wheel events |

Check all service status:
```bash
sudo systemctl status linux-voice-assistant sendspin \
  smart-display-audio-init smart-display-mqtt smart-display-touch-scroll
```

Follow live voice pipeline logs:
```bash
journalctl -u linux-voice-assistant -f
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
   LVA / mpv    Sendspin
  (voice/TTS)   (music)
```

Volume controls:
- **TTS Volume** — `amixer -c seeed2micvoicec cset "name=TTS Volume" 80%`
- **Media Volume** — `amixer -c seeed2micvoicec cset "name=Media Volume" 80%`

> **Note:** `pipewire-alsa` must not be installed — it intercepts ALSA calls at the library level and prevents dmix from working. The setup script explicitly removes it. PipeWire is used only for microphone input.

---

## Customisation

### Wake word

Re-run `./configure.sh` and enter a different wake word model name at the prompt. Supported models include `hey_jarvis`, `ok_nabu`, `hey_mycroft`, and others from OpenWakeWord.

### Mic sensitivity

Adjust the **Mic Sensitivity** slider in HA (the MQTT entity). Higher values boost the microphone preamplifier, improving far-field wake word detection. The value persists across reboots. Default is 63% (0 dB on the WM8960 Capture PGA).

### Touch scroll speed

Edit `/usr/local/bin/touch-scroll.py` and adjust `TICKS_PER_SCREEN` (higher = faster scroll), then restart the service:

```bash
sudo systemctl restart smart-display-touch-scroll
```

### Kiosk URL

Re-run `./configure.sh` and enter a new kiosk URL at the prompt, or edit `~/.config/labwc/autostart` directly.

---

## Troubleshooting

**Audio settings don't persist after reboot**
The seeed DKMS module loads after `alsa-restore` runs. The `smart-display-audio-init` service handles this — check its status and logs. Speaker volume is also re-applied in `~/.config/labwc/autostart` as a safety net.

**"No MCLK configured" in dmesg / aplay fails**
The seeed-voicecard DKMS module was built for a different kernel than the one currently running (common after `apt full-upgrade`). Fix:
```bash
sudo dkms build -m seeed-voicecard -v 0.3 -k $(uname -r) --force
sudo dkms install -m seeed-voicecard -v 0.3 -k $(uname -r) --force
sudo reboot
```

**MQTT entities don't appear in HA**
- Check credentials in `/etc/smart-display/mqtt.env`
- Verify MQTT discovery is enabled in HA's MQTT integration settings
- Check `journalctl -u smart-display-mqtt -f` for connection errors

**Voice assistant not discovered by HA after reboot**
Ensure the ESPHome integration is installed in HA and add the device via **Settings → Devices & Services → ESPHome** using `<hostname>.local` port `6053`.

**Touch scrolling not working**
Check the daemon is running: `systemctl status smart-display-touch-scroll`
View logs: `journalctl -u smart-display-touch-scroll -f`

---

# License

> This project is licensed under the terms of the GNU General Public License v3.0. See the LICENSE.txt file for details.
