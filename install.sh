#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# TuneoutDisplay v2 installer
#
# Target: Raspberry Pi 4B + 7" DSI touchscreen, Raspberry Pi OS Lite 64-bit
# (Trixie). Run as your normal user (not root); it uses sudo where needed.
#
#   ./install.sh                     interactive (re-runs pre-fill saved answers)
#   ./install.sh --non-interactive   use ~/.smart-display-settings as-is (fleets)
#
# Idempotent: safe to re-run. Switching role / audio cleanly disables whatever
# the new configuration doesn't use.
# ─────────────────────────────────────────────────────────────────────────────
set -Eeuo pipefail
# Never die silently: name the failing command and line.
# shellcheck disable=SC2154  # rc is assigned inside the trap itself
trap 'rc=$?; echo -e "\n\033[0;31m✘  install.sh stopped (exit $rc) at ${BASH_SOURCE[0]##*/}:$LINENO: $BASH_COMMAND\033[0m" >&2' ERR

# Resolve before any cd — BASH_SOURCE may be relative ("./install.sh").
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NON_INTERACTIVE=0
ASSUME_YES=0
for arg in "$@"; do
    case "$arg" in
        --non-interactive) NON_INTERACTIVE=1; ASSUME_YES=1 ;;
        -y|--yes)          ASSUME_YES=1 ;;
        -h|--help)         sed -n '2,13p' "$0"; exit 0 ;;
        *) echo "Unknown option: $arg (see --help)"; exit 2 ;;
    esac
done

for f in common kiosk audio voice music mqtt cleanup notes; do
    [ -f "$SCRIPT_DIR/lib/$f.sh" ] || { echo "Missing lib/$f.sh — run 'git pull' in the repo."; exit 1; }
    # shellcheck disable=SC1090
    source "$SCRIPT_DIR/lib/$f.sh"
done
for f in mqtt-bridge.py lib/files/tuneout-kiosk; do
    [ -f "$SCRIPT_DIR/$f" ] || die "Missing $f — run 'git pull' in the repo."
done

# Pinned upstream versions (overridable in the settings file).
DEFAULT_LVA_VERSION="v1.1.16"
DEFAULT_SENDSPIN_VERSION="8.0.0"

# ── Banner & preflight ───────────────────────────────────────────────────────
echo -e "${MAGENTA}${BOLD}"
echo "  TuneoutDisplay v2 — Pi kiosk + Home Assistant voice/audio"
echo -e "${NC}"

section "Preflight"
[ "$EUID" -eq 0 ] && die "Run as your normal user, not root. The script uses sudo as needed."
sudo -v || die "This script needs sudo."
[ "$(uname -m)" = aarch64 ] || warn "Expected 64-bit Raspberry Pi OS (aarch64); found $(uname -m)."
if ! grep -q 'VERSION_CODENAME=trixie' /etc/os-release 2>/dev/null; then
    warn "Expected Raspberry Pi OS Trixie — other releases are untested."
fi
info "User: $CURRENT_USER (UID $USER_ID)"

# ── Configuration ────────────────────────────────────────────────────────────
section "Configuration"
if load_settings; then
    info "Loaded $SETTINGS_FILE — press ENTER to keep each value."
elif [ "$NON_INTERACTIVE" = 1 ]; then
    die "--non-interactive needs $SETTINGS_FILE (run once interactively, or copy one in)."
fi
LVA_VERSION="${LVA_VERSION:-$DEFAULT_LVA_VERSION}"
SENDSPIN_VERSION="${SENDSPIN_VERSION:-$DEFAULT_SENDSPIN_VERSION}"

echo "  Roles:"
echo "    display : kiosk + MQTT. With a speaker: HA announcements (LVA output-only)"
echo "              and optionally a Music Assistant player."
echo -e "    voice   : display + full voice assistant. ${MAGENTA}UNTESTED${NC} (needs a USB voice board)."
echo ""
ask_choice ROLE "Role" display display voice

if [ "$ROLE" = voice ] && [ "${ALLOW_UNTESTED:-no}" != yes ]; then
    untested "The voice role hasn't been tested on hardware yet."
    ask_yesno ALLOW_UNTESTED "Install the untested voice role anyway?" no
    [ "$ALLOW_UNTESTED" = yes ] || die "Re-run and choose the display role, or set ALLOW_UNTESTED=yes."
fi

ask DEVICE_NAME "Device name" "Smart Display"
while :; do
    ask KIOSK_URL "Dashboard URL (e.g. http://homeassistant.local:8123/lovelace/0)" ""
    [[ "$KIOSK_URL" =~ ^https?:// ]] && break
    [ "$NON_INTERACTIVE" = 1 ] && die "KIOSK_URL must start with http:// or https://"
    warn "Enter a full http(s):// URL."
    KIOSK_URL=""
done
# Dark makes Chromium report prefers-color-scheme: dark; HA follows it when the
# dashboard user's Dark Mode is "Auto" (the default).
ask_choice KIOSK_THEME "Kiosk colour scheme" dark dark light

echo ""
echo "  Audio output:"
echo "    none      : no speaker"
echo "    max98357a : MAX98357A I2S amp (to test)"
echo "    wm8960    : Keyestudio/Seeed 2-Mic HAT as a speaker amp only (verify)"
echo -e "    usb       : USB audio, e.g. the voice board's own amp (${MAGENTA}UNTESTED${NC})"
if [ "$ROLE" = voice ]; then
    # The XVF3800/Lite do echo cancellation only on audio played through them.
    info "Voice role uses the voice board's own amp → audio output 'usb'."
    AUDIO_OUTPUT=usb
else
    ask_choice AUDIO_OUTPUT "Audio output" none none max98357a wm8960 usb
fi

if has_audio; then
    ask SPEAKER_VOLUME "Speaker volume %" "80"
    if ! [[ "$SPEAKER_VOLUME" =~ ^[0-9]+$ ]] || [ "$SPEAKER_VOLUME" -gt 100 ]; then
        die "Speaker volume must be 0–100."
    fi
    ask_yesno MUSIC_ASSISTANT "Install the Music Assistant player (sendspin)?" yes
else
    MUSIC_ASSISTANT=no
fi

if [ "$ROLE" = voice ]; then
    ask_yesno WAKE_WORD_ENABLED "Use a wake word? (no = push-to-talk only)" yes
    if [ "$WAKE_WORD_ENABLED" = yes ]; then
        ask WAKE_WORD "Wake word model" "okay_nabu"
    fi
else
    WAKE_WORD_ENABLED="${WAKE_WORD_ENABLED:-yes}"
fi

echo ""
echo "  MQTT (registers the device in HA via discovery):"
ask MQTT_HOST "Broker host" "homeassistant.local"
ask MQTT_PORT "Broker port" "1883"
ask MQTT_USERNAME "Username" ""
if [ -n "$MQTT_USERNAME" ]; then ask_secret MQTT_PASSWORD "Password"; else MQTT_PASSWORD=""; fi

# Expert settings: not prompted, editable in the settings file.
TOUCH_SCROLL="${TOUCH_SCROLL:-no}"
CHROMIUM_EXTRA_FLAGS="${CHROMIUM_EXTRA_FLAGS:-}"
MAX98357A_PARAMS="${MAX98357A_PARAMS:-}"
ALLOW_UNTESTED="${ALLOW_UNTESTED:-no}"

DEVICE_ID="$(device_id_from_name "$DEVICE_NAME")"

echo ""
echo -e "  ${BOLD}Summary${NC}"
printf '    %-16s %s\n' \
    "Role"           "$ROLE" \
    "Device"         "$DEVICE_NAME ($DEVICE_ID)" \
    "Dashboard"      "$KIOSK_URL" \
    "Colour scheme"  "$KIOSK_THEME" \
    "Audio output"   "$AUDIO_OUTPUT" \
    "Music Assistant" "$MUSIC_ASSISTANT" \
    "MQTT"           "$MQTT_HOST:$MQTT_PORT ${MQTT_USERNAME:+(user $MQTT_USERNAME)}"
[ "$ROLE" = voice ] && printf '    %-16s %s\n' "Wake word" \
    "$([ "$WAKE_WORD_ENABLED" = yes ] && echo "$WAKE_WORD" || echo "off (push-to-talk)")"
echo ""

if [ "$ASSUME_YES" != 1 ]; then
    read -rp "Proceed? [Y/n] " c
    [[ "${c:-Y}" =~ ^[Yy] ]] || { echo "Aborted."; exit 0; }
fi
save_settings
sudo mkdir -p "$CONF_DIR"

# ── System update ────────────────────────────────────────────────────────────
section "System update"
# v2 has no out-of-tree kernel modules, so the kernel updates normally.
# Lift v1's kernel hold if this device still has it.
held="$(apt-mark showhold 2>/dev/null | grep -E '^linux-(image|headers)-rpi' || true)"
if [ -n "$held" ]; then
    info "Releasing v1 kernel hold: $(echo "$held" | tr '\n' ' ')"
    # shellcheck disable=SC2086
    sudo apt-mark unhold $held
fi
info "Updating packages (a few minutes on a fresh image)..."
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y -qq
[ -f /var/run/reboot-required ] && REBOOT_REQUIRED=1
success "System up to date."

legacy_cleanup

# ── Role dispatch ────────────────────────────────────────────────────────────
kiosk_install

if has_audio; then
    audio_install
    if [ "$ROLE" = voice ]; then voice_install full; else voice_install output-only; fi
    if [ "$MUSIC_ASSISTANT" = yes ]; then music_install; else music_remove; fi
else
    audio_remove
    voice_remove
    music_remove
fi

mqtt_install
touch_scroll_apply
write_setup_notes

# ── Done ─────────────────────────────────────────────────────────────────────
section "Done"
echo -e "${GREEN}${BOLD}TuneoutDisplay is configured.${NC}"
echo ""
echo "  In Home Assistant:"
echo "   • MQTT → device '$DEVICE_NAME' appears automatically (brightness, screen, dashboard)."
if has_audio; then
    echo "   • ESPHome → Add → host $(hostname).local, port 6053 (announcements / TTS target)."
    [ "$MUSIC_ASSISTANT" = yes ] && echo "   • Music Assistant 2.7+ → player '$DEVICE_NAME' appears automatically."
fi
echo "   • Full notes: ~/smart-display-setup.md"
echo ""
echo "  Status:  sudo systemctl status tuneout-kiosk smart-display-mqtt$(has_audio && echo ' linux-voice-assistant')$([ "$MUSIC_ASSISTANT" = yes ] && echo ' sendspin')"
echo ""

if [ "$REBOOT_REQUIRED" = 1 ]; then
    warn "A reboot is required (boot config or kernel changed)."
    if [ "$NON_INTERACTIVE" = 1 ]; then
        info "Non-interactive: reboot when convenient (sudo reboot)."
    else
        read -rp "Reboot now? [Y/n] " c
        [[ "${c:-Y}" =~ ^[Yy] ]] && sudo reboot
    fi
fi
