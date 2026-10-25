# CLAUDE.md — TuneoutDisplay v2

Authoritative reference for Claude working on this codebase. Read it fully
before making changes. The v2 design brief is `docs/REWRITE.md`; decisions
there are settled unless marked OPEN.

---

## Hardware & OS

| Component | Part / status |
|-----------|---------------|
| SBC | Raspberry Pi 4B (1 GB boards must work) |
| Display | 7" DSI touchscreen. Backlight auto-detected: first entry of `/sys/class/backlight/` (override with `BACKLIGHT_DEVICE` in `mqtt.env`) |
| Speaker (optional) | MAX98357A I2S amp (`max98357a`, to test) · Keyestudio WM8960 2-Mic HAT as amp only (`wm8960`, verify) · USB audio / voice board (`usb`, UNTESTED) |
| Voice board (optional) | reSpeaker XVF3800 (recommended) / ReSpeaker Lite — both UNTESTED |
| OS | Raspberry Pi OS **Lite** 64-bit (Trixie). No desktop. Kernel is **not** held |

No ESP32, no out-of-tree kernel modules, no DKMS. The repo is cloned as
`TuneoutDisplay` (with 'e') on the Pi.

---

## Layout

```
install.sh          entry: preflight, prompts, role dispatch
lib/common.sh       logging, settings, prompts, install_file, boot-config block, apt/systemd helpers
lib/kiosk.sh        cage + Chromium service, touch-scroll fallback
lib/audio.sh        PipeWire, overlays, onboard-audio off, silent mic, WM8960 mixer
lib/voice.sh        LVA (pinned tag), output-only vs full, wake-word-off patch
lib/music.sh        sendspin (pinned version)
lib/mqtt.sh         bridge install, backlight udev rule
lib/cleanup.sh      removes v1 leftovers (no-op on a fresh image)
lib/notes.sh        writes ~/smart-display-setup.md
lib/files/tuneout-kiosk   kiosk launcher (wait for HA → exec Chromium)
mqtt-bridge.py      MQTT discovery bridge
touch-scroll.py     v1 touch→scroll daemon, only used if TOUCH_SCROLL=yes
lovelace/smart-display-card.js   Lovelace card (all entities optional)
```

---

## Roles & settings

`~/.smart-display-settings` (mode 600, written with `printf %q`, re-sourced on
re-run; `install.sh --non-interactive` uses it as-is). Keys are listed in
`SETTINGS_KEYS` in `lib/common.sh` — add new ones there.

| Setting | Values | Notes |
|---|---|---|
| `ROLE` | `display` / `voice` | voice needs `ALLOW_UNTESTED=yes` |
| `AUDIO_OUTPUT` | `none` / `max98357a` / `wm8960` / `usb` | voice role forces `usb` (board's own amp, needed for its AEC) |
| `MUSIC_ASSISTANT` | yes/no | forced `no` without audio |
| `WAKE_WORD_ENABLED`, `WAKE_WORD` | | voice role only |
| `SPEAKER_VOLUME` | 0–100 | default master level |
| `LVA_VERSION`, `SENDSPIN_VERSION` | pinned | defaults in `install.sh` |
| `TOUCH_SCROLL`, `CHROMIUM_EXTRA_FLAGS`, `MAX98357A_PARAMS` | expert | not prompted |

What gets installed:

| | none | display + audio | voice |
|---|---|---|---|
| `tuneout-kiosk` | ✔ | ✔ | ✔ |
| `smart-display-mqtt` | ✔ | ✔ | ✔ |
| `linux-voice-assistant` | ✘ (disabled) | `--output-only` | full |
| `sendspin` | ✘ | if `MUSIC_ASSISTANT=yes` | if `MUSIC_ASSISTANT=yes` |

Every `*_install` has a matching `*_remove`, so switching role/audio on re-run
disables what's no longer used. Keep that pairing when adding features.

---

## Installer conventions

- **`SCRIPT_DIR`** is resolved from `BASH_SOURCE` at the very top of `install.sh`, before anything can `cd`. Keep it that way (v1 lesson).
- **Idempotent.** `install_file` writes only when content differs and sets `FILE_CHANGED`; services restart only when their files changed (kiosk/bridge) or always where cheap. `apt_install` skips installed packages. LVA's slow `script/setup` runs only when `LVA_VERSION` changes (stamp file `~/lva/.tuneout-installed-version`).
- **Boot config:** our lines live in a marked block at the end of `/boot/firmware/config.txt` (`set_boot_block`). Onboard audio is switched with exact-line edits of the stock `dtparam=audio=on` and `dtoverlay=vc4-kms-v3d` lines (`boot_sed`), reverted when audio is `none`. Any change sets `REBOOT_REQUIRED`. `/boot/firmware` is FAT — use `cp`, not `install`.
- **Env files** in `/etc/smart-display/` (`kiosk.env`, `lva.env`, `device.env`, `mqtt.env` 600). Build them with `env_line` (quotes/escapes values). Using EnvironmentFiles avoids systemd `%` specifier and quoting problems in unit files; `${VAR}` (braced) in `ExecStart` passes a value with spaces as one argument.
- User-level services (PipeWire) need **linger** (`loginctl enable-linger`), and system services that talk to them set `XDG_RUNTIME_DIR=/run/user/<uid>`.

---

## Kiosk

- `tuneout-kiosk.service`: `User=<user>`, `PAMName=tuneout-kiosk` (`/etc/pam.d/tuneout-kiosk` includes `pam_systemd` → logind session on seat0/tty1), `TTYPath=/dev/tty1`, `ExecStart=cage -d -- /usr/local/bin/tuneout-kiosk`. Conflicts with `getty@tty1`. If lightdm is enabled the installer disables it.
- **Cursor:** cage centres the cursor at start and is meant to hide it with no pointer device, but on the Pi 4 + DSI touchscreen one still showed mid-screen. The installer ships an all-transparent Xcursor theme (`/usr/share/icons/tuneout-blank`, every name symlinked to one blank image), sets it via `XCURSOR_THEME` in the unit and as the user's default (`~/.icons/default/index.theme` → `Inherits=tuneout-blank`), which covers both wlroots and Chromium. Don't fix this with dashboard CSS.
- Launcher waits for the dashboard's origin (`curl -k`), clears Chromium's crashed-session flag, then execs Chromium.
- **CDP:** `--remote-debugging-port=9222` binds 127.0.0.1. Chromium 136+ ignores it on the default profile, hence `--user-data-dir=~/.local/share/tuneout-kiosk/chromium`. The bridge connects with `suppress_origin=True`, so `--remote-allow-origins` is not used.
- Touch: cage forwards real touch events; Chromium scrolls natively. `touch-scroll.py` is kept only as an opt-in fallback until that's confirmed on hardware — delete it once confirmed.

---

## Audio

```
LVA (mpv → PipeWire)  ─┐
                       ├─► PipeWire ─► default sink (the only one)
sendspin (ALSA default ┘   via pipewire-alsa)
```

- Stock `pipewire`, `pipewire-pulse`, **`pipewire-alsa`** (now required), `wireplumber`. No `/etc/asound.conf`, no softvol, no audio-init service.
- With an output selected, onboard audio (headphone + HDMI) is turned off so the chosen device is the sole sink → automatic default. No WirePlumber priority rules needed.
- **Silent mic (display role):** LVA opens a mic and runs wake-word detection even with `--output-only` (checked in LVA v1.1.16 `__main__.py`). A `support.null-audio-sink` virtual source `tuneout-silent-mic` (`/etc/pipewire/pipewire.conf.d/60-tuneout-silent-mic.conf`) is set as LVA's `AUDIO_INPUT_DEVICE` so it never hears its own playback.
- **Volume:** master = PipeWire default sink via `wpctl` (MQTT Speaker Volume, state in `~/.smart-display-speaker-volume`, re-applied by the bridge at start). TTS volume = LVA's own ESPHome media player. Music = MA → sendspin with `--hardware-volume false` (software volume; without that flag sendspin would drive the master).
- **WM8960:** in-tree `dtoverlay=wm8960-soundcard` (card id `wm8960soundcard`). The codec boots with output mixers off; `/etc/udev/rules.d/91-tuneout-wm8960.rules` runs `/usr/local/sbin/tuneout-wm8960-mixer` on card add (after `90-alsa-restore`). The overlay assumes a 12.288 MHz MCLK — unverified for the Keyestudio HAT.
- **Echo cancellation:** voice boards do it on-chip. Never add PipeWire `module-echo-cancel`.

---

## Voice (LVA)

- Cloned to `~/lva`, checked out at `LVA_VERSION` with `git checkout -f` (also wipes our patch so it's reapplied cleanly). Env → flags mapping is LVA's `docker-entrypoint.sh` (`ENABLE_OUTPUT_ONLY`, `AUDIO_INPUT_DEVICE`, `WAKE_MODEL`, `PERIPHERAL_HOST`, …).
- Peripheral API bound to `127.0.0.1:6055` (upstream default is 0.0.0.0).
- **Wake word off (OPEN upstream):** LVA can't disable it (empty list → default model). `lib/voice.sh` patches the single line `if activated and not state.muted:` to also check `TUNEOUT_WAKE_WORD != "0"`. If a new LVA tag changes that line the installer warns and leaves the wake word on — update `LVA_PATCH_FROM`. Preferred fix: upstream PR adding a no-wake-word option.
- Push-to-talk: MQTT **Start Listening** button → bridge sends `{"command":"start_listening"}` to the peripheral API. Voice-board USR button → same command is still TODO (needs hardware).
- **XVF3800 `_48k2ch` caveat (untested):** LVA records mono by default; PipeWire may downmix both board channels. Check which channel carries the processed beam once hardware arrives.

---

## MQTT bridge

Topics: `smart-display/<device_id>/<entity>/{state,set}`, availability
`…/availability`, discovery `homeassistant/<component>/<device_id>/<entity>/config`.

| Feature (`FEATURES`) | Entity | Backend |
|---|---|---|
| `brightness` | number `brightness` (min 0) | backlight `brightness` |
| `screen` | switch `screen` | backlight `bl_power` (0 on / 4 off) |
| `dashboard` | button `dashboard_reload` + text `dashboard_url` (shared `…/dashboard/set`) | CDP reload/navigate. Payloads: `''`/`reload`/`refresh`, `home`, `http(s)://…` |
| `speaker_volume` | number `speaker_volume` | `wpctl` on `@DEFAULT_AUDIO_SINK@` |
| `talk` | button `talk` | LVA peripheral `start_listening` |

Disabled features and v1's `tts_volume` / `media_volume` / `mic_gain` get an
empty retained config on connect, which deletes them from HA.

Brightness: entity min 0 (automations can turn the panel off); the Lovelace
card slider min is 5 (intentional).

---

## Known gotchas

| Symptom | Cause | Fix |
|---|---|---|
| Black screen, kiosk "running" | Launcher still waiting for HA | `journalctl -u tuneout-kiosk`; check the Pi can reach the dashboard URL |
| Reload/URL do nothing, bridge logs "Debug endpoint unreachable" | Chromium not up yet, or launched without `--user-data-dir` | Check `curl -s 127.0.0.1:9222/json` on the Pi |
| No audio sink after choosing an output | Overlay needs a reboot | Reboot; `aplay -l`, `wpctl status` |
| Music volume changes TTS volume too | sendspin running with hardware volume | Unit must pass `--hardware-volume false` |
| LVA wakes on its own TTS (display role) | Not reading the silent mic | `lva.env` has `AUDIO_INPUT_DEVICE=tuneout-silent-mic`; `pactl list short sources` shows it |
| `Text file busy` during LVA setup | Running LVA holds the venv python | Installer stops the service first |

## Diagnostics

See the `diagnose-display` skill (`.claude/skills/diagnose-display/SKILL.md`).
