# TuneoutDisplay v2 — Rewrite Brief

Handoff spec for the v2 software rewrite (branch `v2.0`). Decisions below are
settled; open items are marked **OPEN**. The housing redesign is happening in
parallel and is out of scope here.

---

## Goals

1. Pi-only. One hardware stack: Raspberry Pi 4B + 7" DSI display + optional USB
   voice board + optional I2S speaker amp. No ESP32 co-processor.
2. Do less. The seeed-voicecard driver is gone, and with it every workaround it forced.
3. Role-based install: the installer only installs what the chosen role needs.
4. Faster, lighter kiosk.

## Hardware matrix

| Component | Status | Notes |
|---|---|---|
| Pi 4B + 7" DSI touch | **Tested** (target test unit) | Backlight path: auto-detect `/sys/class/backlight/*`, don't hardcode `10-0045` |
| MAX98357A I2S amp + 3W speaker | **To test** (test unit) | In-tree overlay `dtoverlay=max98357a`. No DKMS. Mono, playback only |
| reSpeaker Flex XVF3800 Linear (USB, `_48k2ch` firmware) | **UNTESTED** | Recommended voice board. USB Audio Class, plug-and-play. Own amp drives speaker |
| ReSpeaker Lite (USB firmware) | **UNTESTED** | Budget voice board. USB firmware is 16 kHz only — music will sound like a phone |
| Keyestudio ReSpeaker 2-Mic Pi HAT V1.0 (KS0314, WM8960) as speaker amp only | **Assumed working, verify on fresh install** | Playback worked in v1. The v1 failures were all on the mic/capture side. v2 uses in-tree `dtoverlay=wm8960-soundcard` (no DKMS, no kernel hold). **Must test after a fresh Lite install**: `aplay -l`, enable output mixer + `Speaker` control, `speaker-test`. If it fails, use the MAX98357A. Speaker on XH2.54-2P connector. Keyestudio recommends powering the HAT via its micro-USB when driving a speaker. HAT mics ignored |

Every UNTESTED path must say so in the installer prompt and the README.

## Roles

The installer asks once:

| Role | Installs |
|---|---|
| `display` | Kiosk + MQTT bridge (brightness, dashboard reload/URL). If an amp/speaker is present: LVA in `--output-only` mode as an HA announcement/TTS target, plus sendspin as a Music Assistant player |
| `voice` | Everything in `display` + LVA full mode. **UNTESTED** until a USB voice board is in hand. Follow-up prompt: wake word on/off |

Music Assistant (sendspin) is a yes/no prompt in either role when an audio output exists.
**Caldera is dropped.**

### Wake word off — OPEN
LVA has no flag to disable the wake word. If the wake model can't be loaded it
falls back to the default model, and the HA **Mute** switch blocks button-triggered
listening as well. Options, in order of preference:
1. Upstream PR to LVA adding a `--no-wake-word` / `ENABLE_WAKE_WORD=0` option
   that keeps button/peripheral `start_listening` working.
2. Local patch, applied idempotently by the installer.
Push-to-talk triggers: LVA peripheral API (`ws://localhost:6055`, command
`start_listening`) from a small daemon. Sources: the voice board's USR button
(XVF3800/Lite expose buttons) or an HA dashboard button routed over MQTT.

## Base OS & kiosk

- **Raspberry Pi OS Lite 64-bit (Trixie).** No desktop.
- **`cage` + Chromium** as a systemd service (or greetd autologin) on tty1.
  Drop labwc, the labwc autostart, `lxpanel`/`wfbar` kills, and `unclutter`
  (cage hides the cursor with `-d`/no pointer).
- Keep the wait-for-HA loop before launching Chromium.
- Keep CDP (`--remote-debugging-port`, localhost only) for reload/navigate.
  Bind to 127.0.0.1 and drop `--remote-allow-origins=*` if the bridge connects
  without it.
- **Touch:** test native touch scrolling under cage first. `touch-scroll.py` only
  exists because labwc turns touch into pointer events. Delete it if cage +
  Chromium scroll natively.
- Re-check the Chromium flags. Test `--enable-gpu-rasterization` /
  `--ignore-gpu-blocklist` against `chrome://gpu` on V3D. Keep the memory caps
  for 1 GB boards.

## Audio (when present)

- **Stock PipeWire + WirePlumber, `pipewire-alsa` allowed.** The pipewire-alsa ban,
  dmix/softvol `asound.conf`, WirePlumber output-disable config, and
  `smart-display-audio-init` service all go away.
- Separate TTS vs media volume: per-stream volume via WirePlumber/`wpctl`, or
  drop to one volume plus LVA's own volume. **OPEN**, so pick the simplest that
  works with LVA (which plays music through mpv via `--music-output-device`) and
  sendspin.
- Echo cancellation: the XVF3800/Lite do it on-board, so the Pi must not add
  `module-echo-cancel` on top. For the MAX98357A there's no mic, so nothing is needed.
- Installer detects the voice board by USB name (`aplay -l`/`arecord -l`, or
  `pactl list short sinks/sources`) and selects the matching PipeWire nodes.

## Delete outright

- seeed-voicecard DKMS build, `patch_seeed_source`, DKMS post-upgrade checks
- Kernel `apt-mark hold` (no out-of-tree modules remain, so let the kernel update)
- Caldera section + `caldera-asound.conf` drop-in
- `stop-server.py` (HTTP control server, superseded by the MQTT bridge)
- `migrate-to-lva.sh` (wyoming → LVA migration, obsolete)
- WM8960 `amixer numid=13` speaker hacks
- Mic gain entity (WM8960 PGA). Board-side gain is handled by the XMOS chips. Revisit when hardware arrives

## MQTT bridge

- Register only the entities the role installed (discovery payloads conditional).
- Keep: brightness (min 0), dashboard reload button + URL text (shared `…/dashboard/set`).
- Volume entities: only if they still map to something after the PipeWire
  decision above. LVA already exposes its own media player/volume to HA via ESPHome.
- Consider: screen on/off (backlight `bl_power`), idle screen dim schedule.
- Config from `/etc/smart-display/` env files, as today.

## Installer structure

```
install.sh              # entry: preflight, prompts, dispatch by role
lib/common.sh           # logging, settings load/save, idempotency helpers
lib/kiosk.sh            # cage + chromium service
lib/audio.sh            # pipewire, device detection, max98357a overlay
lib/voice.sh            # LVA install + service (full or output-only)
lib/music.sh            # sendspin
lib/mqtt.sh             # bridge install + service
```
- Settings persisted to `~/.smart-display-settings` (keep), with non-interactive
  mode reading the same file (`install.sh --non-interactive`) for fleets.
- Stays idempotent and re-runnable. Switching roles must cleanly disable what
  the new role doesn't use.
- Resolve `SCRIPT_DIR` from `BASH_SOURCE` at the top (keep the existing lesson).

## Docs to update

README (hardware matrix with tested/untested flags), CLAUDE.md (rewrite for v2),
`ha-configuration.md`, `diagnose-display` skill (drop seeed/DKMS checks, add
PipeWire/USB checks), Lovelace card (entities become optional per role).

## Test plan (test unit: Pi 4B + DSI + Keyestudio 2-Mic HAT installed)

The HAT stays on: it is the speaker amp until a USB voice board arrives (its
mics are ignored). The MAX98357A is the fallback if the HAT fails step 2.

1. Fresh Lite image → `install.sh`, role `display`, audio `none`: kiosk boots
   to dashboard, touch scroll works, brightness/screen + reload/URL work from HA.
   (The HAT is harmless with no overlay loaded.)
2. Re-run, audio `wm8960`, reboot: `aplay -l` shows `wm8960soundcard`,
   `speaker-test` plays. HA TTS announcement plays via LVA output-only. Music
   Assistant plays via sendspin. Both at once mix.
3. Reboot ×3: everything returns without manual steps.
4. Re-run installer with no changes: no errors, no duplicate config.
5. Voice role: blocked until hardware arrives. Code paths behind an UNTESTED flag.
