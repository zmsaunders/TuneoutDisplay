# TuneoutDisplay

A countertop smart display built on a Raspberry Pi: a Home Assistant dashboard
kiosk with HA device integration over MQTT, plus optional speaker output for
HA announcements and Music Assistant — and, once a USB voice board is in hand,
a full voice assistant.

## Full Disclosure

This is a project I work on in the evenings, and the initial build and scripting was created in conjunction with Claude AI. I make no guarantees or warranties, and suggest you read through the code base if you aren't comfortable executing code written by an AI agent. I've made every effort to review it and guide it, but as a side project my biggest concern was having something functional and re-usable. I am 100% open to any pull requests or changes anyone wants to submit.

---

## What changed in v2

- **One stack, no out-of-tree drivers.** The seeed-voicecard DKMS driver and every workaround it forced (kernel hold, dmix/softvol, audio-init service, `pipewire-alsa` ban) are gone. The kernel updates normally.
- **Role-based install.** `install.sh` asks for a role and installs only what it needs.
- **Lighter kiosk.** Raspberry Pi OS **Lite** + `cage` + Chromium. No desktop, no labwc.
- **Stock PipeWire** for audio. Caldera, `stop-server.py`, the mic-gain entity and the v1 migration script were dropped.

## Hardware

| Component | Status | Notes |
|---|---|---|
| Raspberry Pi 4B (1 GB+) + 7" DSI touchscreen | **Tested** | Backlight auto-detected under `/sys/class/backlight/` |
| MAX98357A I2S amp + 3 W speaker | **To test** | In-tree `dtoverlay=max98357a`. Mono, playback only |
| Keyestudio ReSpeaker 2-Mic HAT (KS0314, WM8960) as **speaker amp only** | **Verify on fresh install** | In-tree `dtoverlay=wm8960-soundcard`; HAT mics ignored. Speaker on the XH2.54-2P connector; power the HAT from its micro-USB when driving a speaker |
| reSpeaker Flex XVF3800 Linear (USB, `_48k2ch` firmware) | **UNTESTED** | Recommended voice board. USB Audio Class, on-board echo cancellation, drives its own speaker |
| ReSpeaker Lite (USB firmware) | **UNTESTED** | Budget voice board. USB firmware is 16 kHz only — music will sound like a phone call |

### MAX98357A wiring

| MAX98357A | Pi 4 (BCM / physical pin) |
|---|---|
| VIN | 5 V (pin 2 or 4) |
| GND | GND (pin 6) |
| BCLK | GPIO 18 (pin 12) |
| LRC | GPIO 19 (pin 35) |
| DIN | GPIO 21 (pin 40) |
| SD | GPIO 4 (pin 7) — optional; the overlay drives it to mute the amp when idle. If you leave it unconnected set `MAX98357A_PARAMS=no-sdmode` in the settings file |

## Roles

| Role | Installs |
|---|---|
| `display` | Kiosk + MQTT bridge (brightness, screen on/off, dashboard reload/URL). **With a speaker:** LVA in output-only mode (an HA announcement / TTS media player) and, optionally, sendspin as a Music Assistant player |
| `voice` (**UNTESTED**) | Everything in `display` + LVA full voice mode on a USB voice board. Wake word on/off; with it off, use the **Start Listening** button in HA (push-to-talk) |

---

## Setup

### Prerequisites

- **Raspberry Pi OS Lite (64-bit)**, Trixie, flashed with Raspberry Pi Imager (set hostname, user, Wi-Fi and enable SSH in the Imager's settings)
- Home Assistant with the **MQTT** integration (Mosquitto) and discovery enabled
- **ESPHome** integration (only if the display has a speaker)
- **Music Assistant 2.7+** (optional)

### Install

SSH in as your normal user, then:

```bash
sudo apt-get update && sudo apt-get install -y git
git clone https://github.com/YOUR_USERNAME/TuneoutDisplay.git
cd TuneoutDisplay
git checkout v2.0        # until v2 is merged to main
./install.sh
```

The installer asks for: role, device name, dashboard URL, audio output
(`none` / `max98357a` / `wm8960` / `usb`), speaker volume, Music Assistant
yes/no, wake word (voice role), and MQTT broker details. It updates the system,
installs what the role needs, and offers to reboot when a boot setting changed
(audio overlays need one).

Answers are saved to `~/.smart-display-settings` (mode 600). Re-running
pre-fills them. For a fleet, copy a settings file onto a device and run:

```bash
./install.sh --non-interactive
```

Expert settings live only in that file:

| Setting | Default | Purpose |
|---|---|---|
| `CHROMIUM_EXTRA_FLAGS` | empty | Extra Chromium flags, e.g. `--enable-gpu-rasterization --ignore-gpu-blocklist` (check `chrome://gpu`) |
| `TOUCH_SCROLL` | `no` | Re-enable v1's touch→scroll daemon if native touch scrolling doesn't work |
| `MAX98357A_PARAMS` | empty | Overlay params, e.g. `no-sdmode` |
| `LVA_VERSION` | `v1.1.16` | Pinned Linux Voice Assistant tag |
| `SENDSPIN_VERSION` | `8.0.0` | Pinned sendspin version |
| `ALLOW_UNTESTED` | `no` | Must be `yes` to install the voice role non-interactively |

### In Home Assistant

1. **MQTT** — the device appears automatically under Settings → Devices & Services → MQTT.
2. **ESPHome** (speaker only) — Add Integration → ESPHome → host `<hostname>.local`, port `6053`. In the display role the device is a media player you can target with `tts.speak` and announcements; in the voice role, click **Set Up Voice Assistant**.
3. **Music Assistant** (optional) — the player appears automatically.

Device-specific YAML is written to `~/smart-display-setup.md` on every run.

---

## MQTT entities

Registered only for what the role installed. Entities a role doesn't use (and v1's retired volume/mic entities) are removed from HA automatically.

| Entity | When | Backend |
|---|---|---|
| Brightness (number, 0–100) | always | backlight `brightness` (0 turns the panel off) |
| Screen (switch) | always | backlight `bl_power` |
| Reload Dashboard (button) | always | Chromium `Page.reload` over CDP |
| Dashboard URL (text) | always | Chromium `Page.navigate` over CDP |
| Speaker Volume (number, 0–100) | speaker present | PipeWire master (`wpctl`), restored at boot |
| Start Listening (button) | voice role | LVA peripheral API `start_listening` |

### Volume model

- **Speaker Volume** (MQTT) is the master level for everything.
- **LVA's media player** (ESPHome) has its own volume for TTS / announcements.
- **Music Assistant** sets the sendspin player's volume (software volume — it never moves the master).

### Dashboard refresh

Both dashboard entities publish to `smart-display/<device_id>/dashboard/set`:

```
reload                         reload the current page (ignores cache)
home                           go back to the configured dashboard URL
http(s)://…                    navigate to that URL
```

HA's Mosquitto add-on goes down with HA, so trigger the reload from HA once it's back:

```yaml
automation:
  - alias: "Reload smart displays after HA restart"
    triggers:
      - trigger: homeassistant
        event: start
    actions:
      - delay: "00:00:30"
      - action: button.press
        target:
          entity_id: button.<device_id>_reload_dashboard
```

Chromium's debugging port listens on `127.0.0.1` only. Anyone with a shell on the Pi can drive the browser — fine for a kiosk on a trusted LAN.

---

## Lovelace card

1. Copy `lovelace/smart-display-card.js` to `/config/www/` on HA.
2. Settings → Dashboards → ⋮ → Resources → Add: `/local/smart-display-card.js` (JavaScript module).
3. Add a card. Every entity is optional — rows show only for what you list:

```yaml
type: custom:smart-display-card
name: Kitchen Display
brightness_entity: number.kitchen_display_brightness
screen_entity: switch.kitchen_display_screen
speaker_volume_entity: number.kitchen_display_speaker_volume   # speaker present
media_player_entity: media_player.kitchen_display_media_player # LVA volume
satellite_entity: assist_satellite.kitchen_display             # voice role
mute_entity: switch.kitchen_display_mute                       # voice role
talk_entity: button.kitchen_display_start_listening            # voice role
```

The brightness slider stops at 5 % so a stray drag can't black the screen; automations can still use 0.

---

## Services

| Service | When | What |
|---|---|---|
| `tuneout-kiosk` | always | cage + Chromium on tty1; waits for HA before opening the dashboard |
| `smart-display-mqtt` | always | MQTT discovery bridge |
| `linux-voice-assistant` | speaker present | LVA — output-only (display) or full (voice) |
| `sendspin` | speaker + Music Assistant | Music Assistant player |
| `smart-display-touch-scroll` | `TOUCH_SCROLL=yes` | v1 touch→scroll fallback |

Config: `/etc/smart-display/*.env`. Settings: `~/.smart-display-settings`.

```bash
sudo systemctl status tuneout-kiosk smart-display-mqtt linux-voice-assistant sendspin
journalctl -u tuneout-kiosk -f
```

## Audio architecture

```
LVA (mpv) ──┐
            ├──► PipeWire (mixes) ──► default sink ──► MAX98357A / WM8960 / USB board
sendspin ───┘    (pipewire-alsa routes plain-ALSA apps in)
```

When an output is selected, the installer turns off the Pi's onboard audio
(`dtparam=audio=off`, `vc4-kms-v3d,noaudio`) so the chosen device is the only
sink and becomes the default without extra config. In the display role a silent
virtual mic is added for LVA, which opens a microphone even in output-only mode.

---

## Troubleshooting

**Black screen after boot** — the kiosk waits until the dashboard's host answers. Check `journalctl -u tuneout-kiosk -b` and that the Pi can reach HA (`curl -I <dashboard URL>`).

**No sound** — `aplay -l` should list your card (reboot after choosing an output). `wpctl status` should show it as the default sink. `speaker-test -c2 -t wav` plays through PipeWire.

**WM8960 card present but silent** — check `amixer -c wm8960soundcard` shows *Left/Right Output Mixer PCM* on and *Speaker* up. `sudo /usr/local/sbin/tuneout-wm8960-mixer` re-applies them. The in-tree overlay assumes a 12.288 MHz codec clock (Waveshare); if playback is silent or the wrong pitch on the Keyestudio HAT, use the MAX98357A instead.

**MQTT entities missing** — check `/etc/smart-display/mqtt.env`, that discovery is enabled in HA, and `journalctl -u smart-display-mqtt -f`.

**Mouse cursor visible on the kiosk** — the installer sets an invisible cursor theme; re-run `./install.sh` after `git pull`. Check `grep XCURSOR /etc/systemd/system/tuneout-kiosk.service` and `cat ~/.icons/default/index.theme`.

**Touch doesn't scroll** — set `TOUCH_SCROLL=yes` in `~/.smart-display-settings` and re-run `./install.sh --non-interactive`.

More checks: the `diagnose-display` skill (`.claude/skills/diagnose-display/SKILL.md`).

---

# License

> This project is licensed under the terms of the GNU General Public License v3.0. See the LICENSE.txt file for details.
