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
| `sendspin` | Music Assistant native player (sendspin protocol) — installed only when `MUSIC_PLAYER` is `music-assistant`/`both` | user |
| `caldera-music` | Caldera headless Plex player — installed only when `MUSIC_PLAYER` is `caldera`/`both`; **systemd `--user` service**, self-updating | user |
| `smart-display-mqtt` | MQTT bridge — registers HA entities via discovery; also drives Chromium over CDP for dashboard refresh | user |
| `smart-display-audio-init` | Boot-time ALSA init — waits for card, applies codec settings | root (system) |
| `smart-display-touch-scroll` | Touch→scroll daemon using uinput | root (system) |

Credentials for the MQTT bridge are in `/etc/smart-display/mqtt.env` (mode 600).
That file also carries `DASHBOARD_URL` (the kiosk URL, used by the `home`
dashboard command) and `CDP_PORT` (Chromium remote-debugging port, default 9222).

## Music player selection

`configure.sh` prompts for `MUSIC_PLAYER` ∈ {`music-assistant`, `caldera`, `both`}
(saved in `~/.smart-display-settings`). The sendspin and Caldera sections are each
guarded by this value, and each section disables the *other* player's service when
it's not selected, so re-running to switch backends is clean.

Caldera specifics:
- Installed via `curl -fsSL https://releases.caldera.homes/music/headless/install.sh | bash` into `~/caldera-music/`.
- Requires a one-time interactive `caldera-music --login` (Plex device auth) that cannot be scripted; the script prints the manual steps and enables (but cannot start) the service.
- ALSA-device selection could not be verified upstream, so instead of guessing a CLI flag the build forces Caldera's ALSA `default` onto `CALDERA_AUDIO_DEVICE` (default `seeed_media`) via a systemd `--user` drop-in that sets `ALSA_CONFIG_PATH=/etc/smart-display/caldera-asound.conf`. That config re-includes `/usr/share/alsa/alsa.conf` and `/etc/asound.conf` then overrides `pcm.!default`. **This is unverified — confirm coexistence with voice/TTS after first play.**
- Self-updates in the background; the build does not pin its version. The drop-in survives updates.

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

## Kernel policy (pinned to 6.12)

The seeed-voicecard DKMS driver is out-of-tree and breaks on ASoC API changes —
kernel 6.18 removed the legacy `SND_SOC_DAIFMT_CB*_CF*` macros, changed the
`SOC_SINGLE_VALUE` arity, and changed `simple_util_*` signatures, none of which
the HinTak fork handles yet. To keep the fleet reproducible and avoid mid-upgrade
dpkg breakage, `configure.sh` **holds the kernel at the current 6.12 series**:

```bash
sudo apt-mark hold linux-image-rpi-v8 linux-image-rpi-2712 \
                   linux-headers-rpi-v8 linux-headers-rpi-2712
```

- The hold runs in the System Update section *before* `apt full-upgrade`, so the
  upgrade keeps the kernel back while still patching userspace.
- `apt-mark hold` freezes at the **currently installed** version. This assumes the
  device is provisioned from a 6.12-era image. A device already on a newer kernel
  (e.g. one that slipped to 6.18) freezes *there* — re-image it to standardise.
- To intentionally move the fleet to a newer kernel later: validate the seeed
  driver builds and audio works on it on ONE device, extend `patch_seeed_source`
  for any new API breaks, then `apt-mark unhold` + bump.
- Bringing a 6.18 device back to 6.12 in place (apt downgrade) is unreliable on
  Raspberry Pi OS because the boot image (`/boot/firmware/kernel8.img`) is the
  newest installed kernel — re-imaging is the dependable path.

## DKMS / kernel mismatch

After `apt full-upgrade`, the newly installed kernel may not have the seeed-voicecard DKMS module built for it. Symptoms: `dmesg | grep wm8960` shows `No MCLK configured`, all `aplay` attempts fail even with the card enumerated.

`configure.sh` handles this via:
1. After building/installing the module, it runs `dkms autoinstall` to cover all kernels in `/lib/modules/`.
2. A post-upgrade check block detects if the running kernel is missing the module and rebuilds.

### Source patches (`patch_seeed_source`)

The seeed source needs kernel-API fixes that are applied by `patch_seeed_source()`
(defined near the top of `configure.sh`, grep-guarded and idempotent):
- **6.x:** `rtd->id` → `rtd->dai_link->id` (`snd_soc_pcm_runtime` lost `->id`).
- **6.18:** the legacy ASoC clock master/slave DAI-format macros were removed.
  `SND_SOC_DAIFMT_CBM_CFM`/`CBS_CFS`/`CBM_CFS`/`CBS_CFM` →
  `CBP_CFP`/`CBC_CFC`/`CBP_CFC`/`CBC_CFP` (provider/consumer rename) across all
  codec sources (`wm8960.c`, `ac101.c`, `ac108.c`). Symptom if missing:
  `error: 'SND_SOC_DAIFMT_CBM_CFM' undeclared` in `make.log`, which fails the
  kernel's DKMS post-install hook and leaves dpkg half-configured.

**Critical ordering:** `patch_seeed_source` is called *before* `apt full-upgrade`,
not only in the driver section. The upgrade can install a new kernel whose
`header_postinst.d/dkms` hook rebuilds every DKMS module immediately; if the
source is unpatched at that moment the hook fails and blocks the whole upgrade
before the driver section is ever reached.

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
| `button` | `dashboard_reload` | Reload the kiosk page | CDP `Page.reload` via `localhost:CDP_PORT` |
| `text` | `dashboard_url` | Navigate the kiosk to a URL | CDP `Page.navigate` via `localhost:CDP_PORT` |

The button and text entity share one command topic, `…/dashboard/set`. Payload
handling: `''`/`reload`/`refresh` → reload; `home` → navigate to `DASHBOARD_URL`;
`http(s)://…` → navigate to that URL. The bridge reaches Chromium over the Chrome
DevTools Protocol (`--remote-debugging-port=9222 --remote-allow-origins=*` in the
labwc autostart), using the `python3-websocket` package. CDP is a plain TCP/WS
call to localhost, so it works regardless of the bridge's graphical session.

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
| `apt full-upgrade` fails with `header_postinst.d/dkms exited with return code 1`, kernel packages left unconfigured | seeed source won't compile against the new kernel headers (e.g. 6.18 removed the legacy `SND_SOC_DAIFMT_CB*_CF*` macros), failing the kernel's DKMS hook | Patch the source (`patch_seeed_source` logic), then `sudo apt --fix-broken install`. The script now pre-patches before upgrading to prevent this. |
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
