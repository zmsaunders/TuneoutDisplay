# CLAUDE.md — Smart Display Project

This file is the authoritative reference for Claude working on this codebase. Read it fully before making any changes.

---

## Hardware

| Component | Part |
|-----------|------|
| SBC | Raspberry Pi 4B |
| Audio HAT | ReSpeaker 2-Mic Pi HAT (WM8960 codec) |
| Display | 7" DSI touchscreen (Waveshare or official Pi) |
| Backlight controller | I2C address `10-0045` → `/sys/class/backlight/10-0045/` |
| ALSA card name | `seeed2micvoicec` |
| OS | Raspberry Pi OS 64-bit (Trixie), kernel 6.12.x |

---

## Repository layout

```
TuneoutDisplay/          ← repo name on Pi (note the 'e')
├── configure.sh         ← main provisioning script (idempotent, re-runnable)
├── mqtt-bridge.py       ← MQTT discovery bridge (runs as systemd service)
├── stop-server.py       ← HTTP stop-TTS endpoint on port 12345
├── touch-scroll.py      ← touchscreen vertical swipe → scroll wheel daemon
├── lovelace/
│   └── smart-display-card.js   ← custom Lovelace card
├── ha-configuration.md  ← full HA config reference (both devices)
├── migrate-to-lva.sh    ← migration helper (wyoming → LVA)
├── CLAUDE.md            ← this file
└── README.md
```

> **Note:** The repo is cloned as `TuneoutDisplay` (with 'e') on the Pi.

---

## Services

| Service | Description | Runs as |
|---------|-------------|---------|
| `linux-voice-assistant` | LVA voice pipeline (ESPHome protocol, OWW wake word) | user |
| `sendspin` | Music Assistant native player (sendspin protocol) | user |
| `smart-display-mqtt` | MQTT bridge — registers HA entities via discovery | user |
| `smart-display-audio-init` | Boot-time ALSA init — waits for card, applies codec settings | root (system) |
| `smart-display-touch-scroll` | Touch→scroll daemon using uinput | root (system) |

Credentials for the MQTT bridge are in `/etc/smart-display/mqtt.env` (mode 600).

---

## ALSA audio stack

The WM8960 hardware device can only be opened by one process at a time. The stack is:

```
hw:CARD=seeed2micvoicec,DEV=0   ← physical hardware
        │
   seeed_dmix (dmix)            ← software mixer; allows multiple writers
        │
   seeed_shared (plug)          ← general-purpose plug device
       ┌┴──────────────┐
seeed_tts (softvol)    seeed_media (softvol)
  "TTS Volume" ctrl      "Media Volume" ctrl
  used by LVA/mpv        used by sendspin
```

- `seeed_tts` → LVA/voice pipeline via mpv (`ao=alsa` in `~/.config/mpv/mpv.conf`)
- `seeed_media` → Music Assistant via sendspin (`--audio-device seeed_media`)
- The two softvol controls (`TTS Volume`, `Media Volume`) are ALSA mixer elements on the seeed card — they are **not** in the simple mixer interface; use `amixer cset name=...` not `amixer sset`.

**Critical:** `pipewire-alsa` must NOT be installed. It intercepts all ALSA calls at the library level and prevents dmix from opening the hardware device. It is explicitly purged in `configure.sh`. The `pipewire-audio` meta-package also pulls it in, so that is also excluded from the apt install list.

PipeWire is used **only** for microphone input (LVA reads the mic via PipeWire-Pulse). The seeed ALSA output node is disabled in WirePlumber via `/etc/wireplumber/wireplumber.conf.d/50-seeed-disable-output.conf`.

---

## WM8960 speaker volume

The hardware speaker volume is controlled via:

```bash
amixer -c seeed2micvoicec cset numid=13 122,122 -q
```

- `numid=13` = Speaker Playback Volume (stereo, L+R)
- Range: 0–127. Scale: min = −121 dB, step = 1 dB. **0 dB = value 122.**
- **Cannot** be set with `amixer sset 'Speaker Playback Volume' 0dB` — not in simple mixer interface.
- This is applied in two places:
  1. `smart-display-audio-init.sh` — runs at boot, waits for the card
  2. `~/.config/labwc/autostart` — re-applied when the desktop session starts, because the codec registers may not be fully settled when the init service fires. The autostart application is the one that reliably sticks.

---

## DKMS / kernel mismatch

After `apt full-upgrade`, the newly installed kernel may not have the seeed-voicecard DKMS module built for it. Symptoms: `dmesg | grep wm8960` shows `No MCLK configured`, all `aplay` attempts fail even with the card enumerated.

`configure.sh` handles this via:
1. After building/installing the module, it runs `dkms autoinstall` to cover all kernels in `/lib/modules/`.
2. A post-upgrade check block detects if the running kernel is missing the module and rebuilds.

Manual fix if needed:
```bash
sudo dkms build -m seeed-voicecard -v 0.3 -k $(uname -r) --force
sudo dkms install -m seeed-voicecard -v 0.3 -k $(uname -r) --force
sudo reboot
```

---

## MQTT bridge entities

The bridge registers all entities under device `DEVICE_ID` (derived from `DEVICE_NAME`, lowercased + underscored).

| Entity type | ID suffix | Purpose | Backend |
|-------------|-----------|---------|---------|
| `number` | `tts_volume` | Voice/TTS volume 0–100% | `amixer cset name="TTS Volume"` |
| `number` | `media_volume` | Music Assistant volume 0–100% | `amixer cset name="Media Volume"` |
| `number` | `brightness` | Display backlight 0–100% | `/sys/class/backlight/10-0045/brightness` |
| `number` | `mic_gain` | Mic sensitivity 0–100% | `amixer cset numid=1` (WM8960 Capture PGA, ALSA 0–63) |

Brightness min values:
- **MQTT entity min = 0** — allows automations to turn the display fully off
- **Lovelace card slider min = 5** — prevents accidental screen-off when using the card manually

Mic gain mapping: percentage → ALSA value 0–63. Default 63% ≈ ALSA 40 (0 dB on WM8960 Capture PGA). Takes effect immediately — no service restart needed. Allows per-device tuning for different acoustic environments.

State files (persist across reboots):
- `~/.smart-display-tts-volume`
- `~/.smart-display-media-volume`
- `~/.smart-display-mic-gain`

---

## Lovelace card (`smart-display-card.js`)

Custom element `custom:smart-display-card`. Required config keys:

```yaml
type: custom:smart-display-card
name: Smart Display
satellite_entity: assist_satellite.smart_display
tts_volume_entity: number.smart_display_tts_volume
media_volume_entity: number.smart_display_media_volume
brightness_entity: number.smart_display_brightness
mute_entity: switch.smart_display_mute   # optional — enables chip tap-to-mute
mic_gain_entity: number.smart_display_mic_gain   # optional
```

Features:
- Status chip (Standby / Listening… / Responding… / Muted) — tap to toggle mute on the ESPHome switch entity; muted state takes visual priority over pipeline state
- Independent sliders for Assistant volume, Media volume, Brightness, Mic Sensitivity
- Drag-lock: slider values don't update from HA state while the user is dragging
- Brightness slider minimum is 5% (card-enforced, not entity-enforced)

---

## configure.sh key behaviours

- **Idempotent** — safe to re-run. Guards: `dkms status` check before install, `[ -d /opt/sendspin ] ||` before venv creation, `git pull` instead of re-clone, `grep` before patching files.
- **SCRIPT_DIR** is resolved at the very top of the script (line ~18) before any `cd` commands run, using `${BASH_SOURCE[0]}`. This is critical — the script does `cd $LVA_DIR` and `cd $CURRENT_HOME` mid-run, which would cause a late-resolved relative path to point at `~` instead of the repo directory.
- **Companion `.py` files** (`mqtt-bridge.py`, `stop-server.py`, `touch-scroll.py`) must be in the same directory as `configure.sh`. A preflight check warns early if any are missing and suggests `git pull`.
- The script drops `~/smart-display-setup.md` on every run with device-specific HA YAML.

---

## Known gotchas

| Symptom | Root cause | Fix |
|---------|-----------|-----|
| `smart-display-mqtt.service could not be found` | `mqtt-bridge.py` not found during configure run (SCRIPT_DIR resolved to `~`) | `git pull` then re-run `./configure.sh` from inside the repo directory |
| `Text file busy` during LVA setup | Running `linux-voice-assistant` service holds venv Python open | `configure.sh` stops the service before `script/setup`; or `sudo systemctl stop linux-voice-assistant` manually |
| Speaker volume resets on reboot | `alsactl restore` races with driver init; audio-init service may fire before codec settles | Volume is re-applied in labwc autostart (runs after session start, driver fully settled) |
| dmix `unable to install hw params` | `pipewire-alsa` installed and intercepting ALSA | `sudo apt remove --purge pipewire-alsa` then reboot |
| `No MCLK configured` in dmesg, all aplay fails | DKMS module built for old kernel, running new kernel post-upgrade | Rebuild for running kernel (see DKMS section above) |
| Brightness entity accepts 0 but card won't go below 5 | Intentional design — automation can turn screen off; user slider cannot | Expected behaviour |

---

## Diagnostic commands

```bash
# Service status
sudo systemctl status linux-voice-assistant sendspin smart-display-mqtt smart-display-stop

# Live logs
journalctl -u smart-display-mqtt -f
journalctl -u linux-voice-assistant -f

# Verify DKMS module matches running kernel
dkms status seeed-voicecard
uname -r

# Test speaker (should play left channel tone)
aplay -D seeed_tts /usr/share/sounds/alsa/Front_Left.wav

# Check WM8960 hardware speaker value (0dB = 122)
amixer -c seeed2micvoicec cget numid=13

# Check softvol controls exist (they're created lazily on first PCM open)
amixer -c seeed2micvoicec cget "name=TTS Volume"
amixer -c seeed2micvoicec cget "name=Media Volume"

# Verify pipewire-alsa is NOT installed
dpkg -l pipewire-alsa 2>/dev/null | grep ^ii && echo "PROBLEM: pipewire-alsa installed"

# MQTT bridge credentials
sudo cat /etc/smart-display/mqtt.env

# Re-run configure (idempotent — safe to run again to change settings)
cd ~/TuneoutDisplay && git pull && ./configure.sh
```
