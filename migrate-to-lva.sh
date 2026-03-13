#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# migrate-to-lva.sh
# One-shot migration: wyoming-satellite → linux-voice-assistant (LVA)
#
# Run this on an existing Smart Display that was configured with configure.sh.
# It leaves everything else intact (ALSA softvol, MQTT bridge, sendspin,
# kiosk, touch scroll) and only replaces the voice-satellite layer.
#
# Usage:
#   chmod +x migrate-to-lva.sh && ./migrate-to-lva.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${BLUE}▶${NC}  $1"; }
success() { echo -e "${GREEN}✔${NC}  $1"; }
warn()    { echo -e "${YELLOW}⚠${NC}  $1"; }
err()     { echo -e "${RED}✘  ERROR:${NC} $1"; exit 1; }
section() { echo -e "\n${BOLD}${BLUE}━━━  $1  ━━━${NC}\n"; }

[ "$EUID" -eq 0 ] && err "Run as your normal user, not root."

CURRENT_USER=$(whoami)
CURRENT_HOME=$HOME
USER_ID=$(id -u)
LVA_DIR="$CURRENT_HOME/lva"
SOUNDS_DIR="$CURRENT_HOME/sounds"

# ── Read device config from existing MQTT env file ────────────────────────────
MQTT_ENV="/etc/smart-display/mqtt.env"
if [ -f "$MQTT_ENV" ]; then
    DEVICE_NAME=$(sudo cat "$MQTT_ENV" | grep '^DEVICE_NAME=' | cut -d= -f2- | tr -d '"')
else
    DEVICE_NAME="Smart Display"
fi

echo -e "${BOLD}${BLUE}"
echo "  ╔══════════════════════════════════════════════╗"
echo "  ║   Smart Display: Migrate to LVA              ║"
echo "  ║   wyoming-satellite  →  linux-voice-assistant║"
echo "  ╚══════════════════════════════════════════════╝"
echo -e "${NC}"
echo "  Device : $DEVICE_NAME"
echo "  User   : $CURRENT_USER (UID $USER_ID)"
echo "  LVA    : $LVA_DIR"
echo ""

read -rp "Wake word model [hey_jarvis]: " WAKE_WORD
WAKE_WORD="${WAKE_WORD:-hey_jarvis}"
echo ""
read -rp "Proceed? [Y/n] " CONFIRM
CONFIRM="${CONFIRM:-Y}"
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ── 1. Stop and disable old Wyoming services ──────────────────────────────────
section "1 / 7 — Stopping Wyoming services"
for svc in wyoming-satellite wyoming-openwakeword; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        info "Stopping $svc..."
        sudo systemctl stop "$svc"
    fi
    if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
        info "Disabling $svc..."
        sudo systemctl disable "$svc"
    fi
done
success "Wyoming services stopped and disabled."

# ── 2. Install PipeWire and LVA system dependencies ──────────────────────────
section "2 / 7 — Installing dependencies"
info "Updating package lists..."
sudo apt-get update -q

info "Installing PipeWire and LVA build dependencies..."
sudo apt-get install -y \
    pipewire \
    pipewire-bin \
    pipewire-pulse \
    wireplumber \
    pipewire-audio \
    libmpv-dev \
    mpv \
    libasound2-plugins \
    pulseaudio-utils \
    avahi-utils \
    python3-venv \
    python3-dev \
    build-essential \
    jq
# Note: pipewire-alsa is intentionally NOT installed. We keep ALSA applications
# (including mpv) talking to raw ALSA so our existing seeed_tts / seeed_media
# softvol stack continues to function and the MQTT bridge needs no changes.
success "Dependencies installed."

# ── 3. Configure PipeWire ──────────────────────────────────────────────────────
section "3 / 7 — Configuring PipeWire"

# Enable session lingering so pipewire.service (user) survives after the
# autologin session ends or before it starts (headless Pi scenario).
info "Enabling session lingering for $CURRENT_USER..."
sudo loginctl enable-linger "$CURRENT_USER"

# WirePlumber rule: disable the seeed ALSA *output* node inside PipeWire.
# This prevents PipeWire from competing with our dmix for hw:seeed2micvoicec
# playback. The seeed *capture* (mic) node is left enabled — LVA reads the
# mic via the PipeWire-Pulse source.
info "Writing WirePlumber config to disable seeed output node..."
sudo mkdir -p /etc/wireplumber/wireplumber.conf.d
sudo tee /etc/wireplumber/wireplumber.conf.d/50-seeed-disable-output.conf > /dev/null << 'WPEOF'
# Disable PipeWire's ownership of the seeed WM8960 playback path.
# Playback is handled by ALSA softvol (seeed_tts / seeed_media) instead.
# The seeed capture (mic input) node remains enabled for LVA microphone access.
monitor.alsa.rules = [
  {
    matches = [
      { node.name = ~alsa_output.*seeed2micvoicec* }
    ]
    actions = {
      update-props = {
        node.disabled = true
      }
    }
  }
]
WPEOF

# mpv config: force the ALSA audio output backend so libmpv routes TTS audio
# through seeed_tts (softvol → dmix → hw:) rather than PulseAudio.
# This means TTS volume is still controlled by amixer cset — MQTT bridge
# requires no changes.
info "Configuring mpv to use ALSA backend..."
mkdir -p "$CURRENT_HOME/.config/mpv"
cat > "$CURRENT_HOME/.config/mpv/mpv.conf" << 'MPVEOF'
# Force ALSA so mpv uses seeed_tts softvol device for TTS output.
# Keeps TTS volume controllable via amixer cset (unchanged from Wyoming setup).
ao=alsa
MPVEOF

# Start PipeWire user services.  On Trixie/Bookworm these are user units;
# they run under the current user's session bus.
info "Starting PipeWire user services..."
export XDG_RUNTIME_DIR="/run/user/$USER_ID"
systemctl --user daemon-reload
systemctl --user enable pipewire pipewire-pulse wireplumber 2>/dev/null || true
systemctl --user restart pipewire wireplumber 2>/dev/null || true
systemctl --user restart pipewire-pulse 2>/dev/null || true
sleep 3

if systemctl --user is-active --quiet pipewire 2>/dev/null; then
    success "PipeWire is running."
    info "PipeWire sources (should include seeed capture):"
    pactl list sources short 2>/dev/null | head -10 || true
else
    warn "PipeWire not yet active in this session — it will start on next boot."
    warn "The LVA service will retry automatically (RestartSec=5)."
fi
success "PipeWire configured."

# ── 4. Install / update LVA ───────────────────────────────────────────────────
section "4 / 7 — Installing Linux Voice Assistant"

if [ ! -d "$LVA_DIR" ]; then
    info "Cloning linux-voice-assistant..."
    git clone https://github.com/OHF-Voice/linux-voice-assistant "$LVA_DIR"
else
    info "LVA already present — pulling latest..."
    git -C "$LVA_DIR" pull
fi

info "Running LVA setup (downloads wake word models — may take a few minutes)..."
chmod +x "$LVA_DIR/docker-entrypoint.sh"
cd "$LVA_DIR"
# Pi 4B: -j2 is safe; change to -j1 for Pi Zero / Pi 3
script/setup --cxxflags="-O1 -g0" --makeflags="-j2"
cd "$CURRENT_HOME"
success "LVA installed."

# ── 5. Create systemd service ─────────────────────────────────────────────────
section "5 / 7 — Creating linux-voice-assistant.service"

# Ensure sounds exist (re-generate if missing)
if [ ! -f "$SOUNDS_DIR/awake.wav" ] || [ ! -f "$SOUNDS_DIR/done.wav" ]; then
    warn "Sound files missing — regenerating..."
    mkdir -p "$SOUNDS_DIR"
    sox -n -r 22050 -c 1 /tmp/sd_t1.wav synth 0.12 sine 587 fade l 0.005 0.12 0.02
    sox -n -r 22050 -c 1 /tmp/sd_t2.wav synth 0.18 sine 880 fade l 0.005 0.18 0.04
    sox /tmp/sd_t1.wav /tmp/sd_t2.wav "$SOUNDS_DIR/awake.wav"
    rm -f /tmp/sd_t1.wav /tmp/sd_t2.wav
    sox -n -r 22050 -c 1 /tmp/sd_t1.wav synth 0.12 sine 880 fade l 0.005 0.12 0.02
    sox -n -r 22050 -c 1 /tmp/sd_t2.wav synth 0.15 sine 494 fade l 0.005 0.15 0.05
    sox /tmp/sd_t1.wav /tmp/sd_t2.wav "$SOUNDS_DIR/done.wav"
    rm -f /tmp/sd_t1.wav /tmp/sd_t2.wav
    success "Sound files created."
fi

info "Writing /etc/systemd/system/linux-voice-assistant.service..."
sudo tee /etc/systemd/system/linux-voice-assistant.service > /dev/null << EOF
[Unit]
Description=Linux Voice Assistant
After=network-online.target smart-display-audio-init.service
Wants=network-online.target

[Service]
Type=simple
User=$CURRENT_USER
WorkingDirectory=$LVA_DIR
Environment=PATH=$LVA_DIR/.venv/bin:/usr/bin:/bin

# PipeWire-Pulse socket — provides the PulseAudio-compatible interface for
# LVA's microphone input.  Playback goes through ALSA directly (see ao=alsa
# in ~/.config/mpv/mpv.conf) so the MQTT bridge / ALSA softvol are unchanged.
Environment=PULSE_SERVER="/run/user/$USER_ID/pulse/native"
Environment=XDG_RUNTIME_DIR="/run/user/$USER_ID"
Environment=PULSE_COOKIE="$LVA_DIR/tmp_pulse_cookie"
ExecStartPre=/usr/bin/touch $LVA_DIR/tmp_pulse_cookie

Environment=PREFERENCES_FILE="$LVA_DIR/preferences.json"
Environment=CLIENT_NAME="$DEVICE_NAME"
Environment=WAKE_MODEL="$WAKE_WORD"

# Route TTS playback through the ALSA seeed_tts softvol device (volume is
# controlled by amixer cset name="TTS Volume" — same as Wyoming setup).
Environment=AUDIO_OUTPUT_DEVICE="alsa/seeed_tts"

# Sound cues (same files used by wyoming-satellite)
Environment=WAKEUP_SOUND="$SOUNDS_DIR/awake.wav"
Environment=PROCESSING_SOUND="$SOUNDS_DIR/done.wav"

ExecStart=$LVA_DIR/docker-entrypoint.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable linux-voice-assistant
sudo systemctl start linux-voice-assistant
sleep 3
success "linux-voice-assistant service enabled and started."

# ── 6. Service status check ───────────────────────────────────────────────────
section "6 / 7 — Checking service status"

echo ""
systemctl status linux-voice-assistant --no-pager -l | head -25 || true
echo ""
info "Live logs (Ctrl-C to exit):"
echo "  journalctl -u linux-voice-assistant -f"
echo ""

# ── 7. HA integration instructions ───────────────────────────────────────────
section "7 / 7 — Home Assistant setup"

DEVICE_IP=$(hostname -I | awk '{print $1}')

echo -e "${GREEN}${BOLD}Migration complete!${NC}"
echo ""
echo "  ┌─────────────────────────────────────────────────────────────┐"
echo "  │  Next steps                                                 │"
echo "  │                                                             │"
echo "  │  1. In HA, remove the old Wyoming Protocol integration:    │"
echo "  │     Settings → Devices & Services → Wyoming Protocol        │"
echo "  │     → (three dots) → Delete                                 │"
echo "  │                                                             │"
echo "  │  2. Add the ESPHome integration:                            │"
echo "  │     Settings → Devices & Services → Add Integration         │"
echo "  │     → ESPHome → Set up another instance of ESPHome          │"
printf "  │     IP: %-15s  Port: 6053                    │\n" "$DEVICE_IP"
echo "  │                                                             │"
echo "  │  3. Click 'Set Up Voice Assistant' — it should now work!   │"
echo "  │                                                             │"
echo "  │  4. Volume/brightness/stop controls are unchanged           │"
echo "  │     (MQTT bridge + ALSA softvol still active)               │"
echo "  └─────────────────────────────────────────────────────────────┘"
echo ""
echo "  To monitor LVA:"
echo "    journalctl -u linux-voice-assistant -f"
echo ""
echo "  To roll back:"
echo "    sudo systemctl stop linux-voice-assistant"
echo "    sudo systemctl start wyoming-satellite wyoming-openwakeword"
echo ""
