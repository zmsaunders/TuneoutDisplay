---
name: diagnose-display
description: Diagnostic commands for a TuneoutDisplay v2 Pi — service status and logs, kiosk/cage/Chromium and CDP checks, PipeWire sinks/sources, overlays and onboard-audio state, WM8960 mixer, USB voice board detection, LVA and sendspin, MQTT config. Use when troubleshooting the kiosk, audio, voice or the MQTT bridge on a device.
---

# TuneoutDisplay v2 diagnostics

Run on the Pi (not the dev machine), as the display's normal user.

```bash
# What did the installer configure?
cat ~/.smart-display-settings | grep -v PASSWORD
ls /etc/smart-display/

# Services
sudo systemctl status tuneout-kiosk smart-display-mqtt linux-voice-assistant sendspin --no-pager
journalctl -u tuneout-kiosk -b --no-pager | tail -50
journalctl -u smart-display-mqtt -f
journalctl -u linux-voice-assistant -f
journalctl -u sendspin -f
```

## Kiosk

```bash
loginctl list-sessions                     # expect a session on seat0 / tty1 for the user
curl -s http://127.0.0.1:9222/json | head  # CDP up? should list a "page" target
cat /etc/smart-display/kiosk.env
ls /sys/class/backlight/                   # backlight device the bridge will use
```

## Audio

```bash
grep -A5 'tuneout-display' /boot/firmware/config.txt   # managed overlay block
grep -E '^dtparam=audio|^dtoverlay=vc4' /boot/firmware/config.txt  # onboard audio should be off with a speaker
aplay -l                                   # card present? (max98357a / wm8960soundcard / USB)
wpctl status                               # default sink (*) should be that card
wpctl get-volume @DEFAULT_AUDIO_SINK@
pactl list short sinks
pactl list short sources                   # display role: tuneout-silent-mic should exist
speaker-test -c2 -t wav -l1                # plays through PipeWire
dpkg -l pipewire-alsa | grep ^ii           # v2 REQUIRES pipewire-alsa
```

WM8960 HAT as speaker:

```bash
amixer -c wm8960soundcard sget 'Left Output Mixer PCM'
amixer -c wm8960soundcard sget Speaker
sudo /usr/local/sbin/tuneout-wm8960-mixer  # re-apply mixer settings
```

USB voice board (UNTESTED path):

```bash
cat /proc/asound/cards | grep -iE 'xvf3800|respeaker'
arecord -l
```

## Voice (LVA)

```bash
cat /etc/smart-display/lva.env
git -C ~/lva describe --tags               # should match LVA_VERSION
git -C ~/lva diff --stat                   # only the wake-word patch, and only if wake word is off
```

## MQTT

```bash
sudo cat /etc/smart-display/mqtt.env       # broker, FEATURES, DEVICE_ID
mosquitto_sub -h <broker> -u <user> -P <pass> -t 'smart-display/#' -v   # from any machine
```

## Re-run the installer (idempotent)

```bash
cd ~/TuneoutDisplay && git pull && ./install.sh
```
