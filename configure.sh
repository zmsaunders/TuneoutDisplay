#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# Smart Display Configuration Script
# Tested on: Raspberry Pi OS 64-bit (Trixie), kernel 6.12.x
# Hardware:  Raspberry Pi 4B + ReSpeaker 2-Mic Pi HAT (WM8960)
#
# Run this script on a fresh Raspberry Pi OS install, logged in as your
# normal user (not root). It will use sudo where needed.
#
# Usage:
#   chmod +x configure.sh && ./configure.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${BLUE}▶${NC}  $1"; }
success() { echo -e "${GREEN}✔${NC}  $1"; }
warn()    { echo -e "${YELLOW}⚠${NC}  $1"; }
err()     { echo -e "${RED}✘  ERROR:${NC} $1"; exit 1; }
section() { echo -e "\n${BOLD}${BLUE}━━━  $1  ━━━${NC}\n"; }

# ── Banner ────────────────────────────────────────────────────────────────────
clear
echo -e "${BOLD}${BLUE}"
cat << 'EOF'
  ____                       _     ____  _           _
 / ___| _ __ ___   __ _ _ __| |_  |  _ \(_)___ _ __ | | __ _ _   _
 \___ \| '_ ` _ \ / _` | '__| __| | | | | / __| '_ \| |/ _` | | | |
  ___) | | | | | | (_| | |  | |_  | |_| | \__ \ |_) | | (_| | |_| |
 |____/|_| |_| |_|\__,_|_|   \__| |____/|_|___/ .__/|_|\__,_|\__, |
                                               |_|             |___/
EOF
echo -e "${NC}"
echo -e "  Hardware : ${BOLD}Raspberry Pi 4B + ReSpeaker 2-Mic HAT${NC}"
echo -e "  OS       : ${BOLD}Raspberry Pi OS 64-bit (Trixie)${NC}"
echo ""

# ── Preflight ─────────────────────────────────────────────────────────────────
section "Preflight Checks"

[ "$EUID" -eq 0 ] && err "Do not run as root — run as your normal user. The script will sudo as needed."

CURRENT_USER=$(whoami)
CURRENT_HOME=$HOME
USER_ID=$(id -u)
info "User: $CURRENT_USER (UID $USER_ID)  |  Home: $CURRENT_HOME"

if ! command -v raspi-config &>/dev/null; then
    warn "raspi-config not found — this may not be a Raspberry Pi OS install."
fi
success "Preflight OK."

# ── Configuration ─────────────────────────────────────────────────────────────
section "Configuration"

echo "Enter values below. Press ENTER to accept the default shown in [brackets]."
echo ""

read -rp "  Device name              [Smart Display]: " DEVICE_NAME
DEVICE_NAME="${DEVICE_NAME:-Smart Display}"

read -rp "  Home Assistant URL  [http://homeassistant.local:8123]: " HA_SERVER
HA_SERVER="${HA_SERVER:-http://homeassistant.local:8123}"

read -rp "  Wake word model          [hey_jarvis]: " WAKE_WORD
WAKE_WORD="${WAKE_WORD:-hey_jarvis}"

read -rp "  Lovelace kiosk URL (leave blank to skip kiosk setup): " KIOSK_URL
KIOSK_URL="${KIOSK_URL:-}"

echo ""
echo "  ── MQTT (for HA device auto-discovery) ──"
echo "  The MQTT bridge registers volume, brightness, and Stop TTS"
echo "  directly in HA — no rest_command YAML needed."
echo ""
read -rp "  MQTT broker host    [homeassistant.local]: " MQTT_HOST
MQTT_HOST="${MQTT_HOST:-homeassistant.local}"

read -rp "  MQTT broker port    [1883]: " MQTT_PORT
MQTT_PORT="${MQTT_PORT:-1883}"

read -rp "  MQTT username       (leave blank if none): " MQTT_USERNAME
MQTT_USERNAME="${MQTT_USERNAME:-}"

if [ -n "$MQTT_USERNAME" ]; then
    read -rsp "  MQTT password: " MQTT_PASSWORD
    echo ""
else
    MQTT_PASSWORD=""
fi

echo ""
echo -e "  ${BOLD}Summary${NC}"
echo "  ┌────────────────────────────────────────────────────────┐"
printf  "  │  Device name  : %-38s│\n" "$DEVICE_NAME"
printf  "  │  HA server    : %-38s│\n" "$HA_SERVER"
printf  "  │  Wake word    : %-38s│\n" "$WAKE_WORD"
printf  "  │  Kiosk URL    : %-38s│\n" "$([ -n "$KIOSK_URL" ] && echo "${KIOSK_URL:0:38}" || echo "skipped")"
printf  "  │  MQTT broker  : %-38s│\n" "${MQTT_HOST}:${MQTT_PORT}"
printf  "  │  MQTT auth    : %-38s│\n" "$([ -n "$MQTT_USERNAME" ] && echo "yes (${MQTT_USERNAME})" || echo "none")"
echo "  └────────────────────────────────────────────────────────┘"
echo ""

read -rp "Proceed with configuration? [Y/n] " CONFIRM
CONFIRM="${CONFIRM:-Y}"
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# Derived identifiers — used throughout the script and in the generated README.
DEVICE_ID=$(echo "$DEVICE_NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '_' | tr -cd 'a-z0-9_')
DEVICE_HOSTNAME=$(hostname)

# ── System Update ─────────────────────────────────────────────────────────────
section "System Update"

info "Updating package lists..."
sudo apt update -qq
info "Upgrading packages (this may take a few minutes)..."
sudo apt full-upgrade -y -qq
success "System up to date."

# ── Dependencies ──────────────────────────────────────────────────────────────
section "Installing Dependencies"

info "Installing dependencies..."
sudo apt install -y \
    git sox alsa-utils unclutter-xfixes python3-paho-mqtt python3-evdev \
    avahi-daemon avahi-utils \
    pipewire pipewire-bin pipewire-pulse wireplumber \
    libmpv-dev mpv libasound2-plugins pulseaudio-utils \
    python3-venv python3-dev build-essential jq
# Note: pipewire-audio (meta-package) and pipewire-alsa are intentionally
# omitted. pipewire-audio pulls in pipewire-alsa which intercepts all ALSA
# calls at the library level, preventing dmix from opening the hardware
# device directly. ALSA apps (mpv, aplay) must use the raw softvol stack.

# Explicitly remove pipewire-alsa in case it was already installed (e.g. as
# a leftover from a previous run or pulled in by an unrelated package).
sudo apt remove --purge -y pipewire-alsa 2>/dev/null || true
success "Dependencies installed."

# ── ReSpeaker 2-Mic HAT Driver ────────────────────────────────────────────────
section "ReSpeaker 2-Mic HAT Driver (seeed-voicecard)"

SEEED_DIR="$CURRENT_HOME/seeed-voicecard"

if [ -d "$SEEED_DIR" ]; then
    warn "seeed-voicecard directory already exists — pulling latest..."
    git -C "$SEEED_DIR" pull
else
    info "Cloning seeed-voicecard (HinTak fork, kernel 6.x compatible)..."
    git clone https://github.com/HinTak/seeed-voicecard "$SEEED_DIR"
fi

# Only run install.sh if the DKMS module is not already registered.
if dkms status seeed-voicecard 2>/dev/null | grep -q "seeed-voicecard"; then
    info "seeed-voicecard DKMS module already registered — skipping install.sh."
else
    info "Running install.sh..."
    cd "$SEEED_DIR"
    sudo ./install.sh
    cd "$CURRENT_HOME"
fi

# Kernel 6.x compatibility patch:
# snd_soc_pcm_runtime lost its 'id' member; replaced by dai_link->id.
SEEED_SOURCE="/usr/src/seeed-voicecard-0.3/seeed-voicecard.c"

if [ ! -f "$SEEED_SOURCE" ]; then
    warn "Could not find $SEEED_SOURCE — skipping DKMS patch/build."
else
    if grep -q "rtd->id" "$SEEED_SOURCE"; then
        info "Applying kernel 6.x API patch (rtd->id → rtd->dai_link->id)..."
        sudo sed -i 's/rtd->id/rtd->dai_link->id/g' "$SEEED_SOURCE"
        success "Patch applied."
    else
        info "Patch already applied or not needed — skipping."
    fi

    info "Building DKMS module for kernel $(uname -r)..."
    if sudo dkms build -m seeed-voicecard -v 0.3 --force 2>&1 | grep -q "Error"; then
        err "DKMS build failed. Check: /var/lib/dkms/seeed-voicecard/0.3/build/make.log"
    fi
    sudo dkms install -m seeed-voicecard -v 0.3 --force

    # apt full-upgrade above may have installed a newer kernel that will become
    # active after the reboot at the end of this script.  dkms autoinstall
    # ensures the module is built and installed for every kernel found in
    # /lib/modules/, including any newly upgraded one.
    info "Running dkms autoinstall to cover all installed kernels..."
    sudo dkms autoinstall -m seeed-voicecard -v 0.3 2>/dev/null || true
    success "seeed-voicecard DKMS module installed."
fi

# ── DKMS Kernel Version Check ────────────────────────────────────────────────
# apt full-upgrade (run above) may have installed a newer kernel that will be
# active after the reboot at the end of this script.  If the running kernel
# was itself upgraded since the last configure run, the seeed module for the
# CURRENT kernel may also be missing.  Detect and rebuild so audio works on
# first boot without requiring a second run of the script.
_RUNNING_KERNEL="$(uname -r)"
if dkms status seeed-voicecard 2>/dev/null | grep -q "seeed-voicecard"; then
    if ! dkms status seeed-voicecard 2>/dev/null | grep -q "$_RUNNING_KERNEL"; then
        warn "seeed-voicecard DKMS module missing for running kernel $_RUNNING_KERNEL — rebuilding..."
        sudo dkms build   -m seeed-voicecard -v 0.3 -k "$_RUNNING_KERNEL" --force 2>&1 | grep -v "^$" || true
        sudo dkms install -m seeed-voicecard -v 0.3 -k "$_RUNNING_KERNEL" --force \
            || warn "DKMS install failed — audio requires a reboot then re-run of this script."
        success "seeed-voicecard rebuilt for $_RUNNING_KERNEL."
    else
        success "seeed-voicecard DKMS module current for kernel $_RUNNING_KERNEL."
    fi
fi

# ── Microphone Wrapper Script (diagnostic / fallback) ─────────────────────────
section "Microphone Wrapper Script"

# LVA handles microphone input internally via PipeWire-Pulse, so mic.sh is no
# longer used by the voice pipeline.  It is kept here as a handy diagnostic
# tool: running mic.sh | aplay confirms the hardware capture path is working
# independently of PipeWire.
MIC_SCRIPT="$CURRENT_HOME/mic.sh"

cat > "$MIC_SCRIPT" << 'MICEOF'
#!/bin/bash
# Records stereo 48kHz (WM8960 native rate) and converts to 16kHz mono.
# Kept for diagnostics — LVA uses PipeWire for mic input, not this script.
arecord -D hw:CARD=seeed2micvoicec,DEV=0 -r 48000 -c 2 -f S16_LE -t raw | \
    sox -t raw -r 48000 -L -e signed -b 16 -c 2 - \
        -t raw -r 16000 -L -e signed -b 16 -c 1 -
MICEOF

chmod +x "$MIC_SCRIPT"
success "mic.sh created at $MIC_SCRIPT (diagnostic use only)"

# ── ALSA Shared Output (dmix) ─────────────────────────────────────────────────
section "ALSA Shared Output (dmix)"

# The WM8960 hardware device can only be opened by one process at a time.
# dmix creates a software mixer so Wyoming's aplay (TTS) and sendspin (music)
# can share the hardware output simultaneously without blocking each other.
info "Creating /etc/asound.conf with dmix virtual device..."
sudo tee /etc/asound.conf > /dev/null << 'ALSAEOF'
# ── seeed WM8960 shared audio stack ──────────────────────────────────────────
#
# seeed_dmix   hardware dmix — allows multiple writers to the WM8960 at once
# seeed_shared plug over dmix — general purpose / ad-hoc use
# seeed_tts    softvol over seeed_shared — LVA/TTS playback (independent vol)
# seeed_media  softvol over seeed_shared — Music Assistant playback (independent vol)
#
# LVA (linux-voice-assistant) uses seeed_tts via mpv (ao=alsa); sendspin uses seeed_media.
# Each has its own ALSA mixer control ("TTS Volume" / "Media Volume") so the
# two streams can be adjusted independently from Home Assistant without
# affecting each other or the WM8960 hardware Speaker level.

pcm.seeed_dmix {
    type dmix
    ipc_key 1024
    slave {
        pcm "hw:CARD=seeed2micvoicec,DEV=0"
        rate 48000
        channels 2
        period_size 1024
        buffer_size 8192
    }
}

pcm.seeed_shared {
    type plug
    slave.pcm "seeed_dmix"
    hint {
        show on
        description "Seeed 2-Mic voicecard (shared)"
    }
}

pcm.seeed_tts {
    type softvol
    slave.pcm "seeed_shared"
    control {
        name "TTS Volume"
        card "seeed2micvoicec"
    }
    hint {
        show on
        description "Seeed 2-Mic voicecard (TTS/voice)"
    }
}

pcm.seeed_media {
    type softvol
    slave.pcm "seeed_shared"
    control {
        name "Media Volume"
        card "seeed2micvoicec"
    }
    hint {
        show on
        description "Seeed 2-Mic voicecard (media)"
    }
}
ALSAEOF
success "ALSA dmix config written."

# ── PipeWire Audio Server ─────────────────────────────────────────────────────
section "PipeWire Audio Server"

# PipeWire (via pipewire-pulse) provides the PulseAudio-compatible socket that
# LVA requires for microphone input.  Playback stays on the raw ALSA softvol
# stack — mpv is configured to use ao=alsa so TTS volume is still controlled
# by amixer cset and the MQTT bridge needs no changes.

# Enable session lingering so PipeWire user services survive autologin / boot.
info "Enabling session lingering for $CURRENT_USER..."
sudo loginctl enable-linger "$CURRENT_USER"

# WirePlumber rule: disable the seeed ALSA *output* node in PipeWire.
# This prevents PipeWire from competing with our ALSA dmix for the WM8960
# playback path.  The seeed *capture* (mic input) node stays enabled so
# LVA can read the microphone via the PipeWire-Pulse source.
info "Writing WirePlumber config (disable seeed output node)..."
sudo mkdir -p /etc/wireplumber/wireplumber.conf.d
sudo tee /etc/wireplumber/wireplumber.conf.d/50-seeed-disable-output.conf > /dev/null << 'WPEOF'
# Disable PipeWire ownership of the seeed WM8960 playback path.
# Playback is handled by ALSA softvol (seeed_tts / seeed_media via dmix).
# The seeed capture (mic) node remains enabled for LVA microphone access.
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

# mpv config: force ALSA output backend so TTS audio goes through
# seeed_tts (softvol → dmix → hw:) rather than PulseAudio.
info "Configuring mpv to use ALSA backend..."
mkdir -p "$CURRENT_HOME/.config/mpv"
cat > "$CURRENT_HOME/.config/mpv/mpv.conf" << 'MPVEOF'
# Force ALSA so mpv routes TTS audio through the seeed_tts softvol device.
# Keeps TTS volume controllable via amixer cset — MQTT bridge unchanged.
ao=alsa
MPVEOF

# Start PipeWire user services.
export XDG_RUNTIME_DIR="/run/user/$USER_ID"
systemctl --user daemon-reload 2>/dev/null || true
systemctl --user enable pipewire pipewire-pulse wireplumber 2>/dev/null || true
systemctl --user restart pipewire wireplumber 2>/dev/null || true
systemctl --user restart pipewire-pulse 2>/dev/null || true
sleep 3

if systemctl --user is-active --quiet pipewire 2>/dev/null; then
    success "PipeWire running."
else
    warn "PipeWire not active in this session — will start on next boot/login."
fi
success "PipeWire configured."

# ── Linux Voice Assistant ─────────────────────────────────────────────────────
section "Linux Voice Assistant"

# LVA (github.com/OHF-Voice/linux-voice-assistant) replaces wyoming-satellite.
# It uses the ESPHome protocol — add it to HA via the ESPHome integration.
# Built-in wake word detection via OpenWakeWord (no separate OWW service needed).

LVA_DIR="$CURRENT_HOME/lva"

if [ -d "$LVA_DIR" ]; then
    warn "LVA already present — pulling latest..."
    git -C "$LVA_DIR" pull
else
    info "Cloning linux-voice-assistant..."
    git clone https://github.com/OHF-Voice/linux-voice-assistant "$LVA_DIR"
fi

info "Running LVA setup (downloads wake word models — may take a few minutes)..."
chmod +x "$LVA_DIR/docker-entrypoint.sh"

# Stop the service before rebuilding the venv — if LVA is already running it
# holds the venv Python binary open, causing "Text file busy" when setup tries
# to overwrite it.
sudo systemctl stop linux-voice-assistant 2>/dev/null || true

cd "$LVA_DIR"
# Pi 4B: -j2 is safe.  Change to -j1 for Pi Zero / Pi 3.
script/setup --cxxflags="-O1 -g0" --makeflags="-j2"
cd "$CURRENT_HOME"
success "LVA installed."

# ── Pipeline Audio Feedback Sounds ────────────────────────────────────────────
section "Pipeline Audio Feedback Sounds"

SOUNDS_DIR="$CURRENT_HOME/sounds"
mkdir -p "$SOUNDS_DIR"

info "Generating awake chime (ascending — signals start of listening)..."
sox -n -r 22050 -c 1 /tmp/sd_t1.wav synth 0.12 sine 587 fade l 0.005 0.12 0.02
sox -n -r 22050 -c 1 /tmp/sd_t2.wav synth 0.18 sine 880 fade l 0.005 0.18 0.04
sox /tmp/sd_t1.wav /tmp/sd_t2.wav "$SOUNDS_DIR/awake.wav"
rm -f /tmp/sd_t1.wav /tmp/sd_t2.wav
success "awake.wav created."

info "Generating done chime (descending — signals end of pipeline)..."
sox -n -r 22050 -c 1 /tmp/sd_t1.wav synth 0.12 sine 880 fade l 0.005 0.12 0.02
sox -n -r 22050 -c 1 /tmp/sd_t2.wav synth 0.15 sine 494 fade l 0.005 0.15 0.05
sox /tmp/sd_t1.wav /tmp/sd_t2.wav "$SOUNDS_DIR/done.wav"
rm -f /tmp/sd_t1.wav /tmp/sd_t2.wav
success "done.wav created."

# ── Linux Voice Assistant Service ─────────────────────────────────────────────
section "Linux Voice Assistant Service"

info "Creating linux-voice-assistant.service..."
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

# PipeWire-Pulse socket — provides the PulseAudio-compatible interface LVA
# uses for microphone input.
Environment=PULSE_SERVER="/run/user/$USER_ID/pulse/native"
Environment=XDG_RUNTIME_DIR="/run/user/$USER_ID"
Environment=PULSE_COOKIE="$LVA_DIR/tmp_pulse_cookie"
ExecStartPre=/usr/bin/touch $LVA_DIR/tmp_pulse_cookie

Environment=PREFERENCES_FILE="$LVA_DIR/preferences.json"
Environment=CLIENT_NAME="$DEVICE_NAME"
Environment=WAKE_MODEL="$WAKE_WORD"

# Route TTS output through the seeed_tts ALSA softvol device (ao=alsa is set
# in ~/.config/mpv/mpv.conf).  TTS volume remains controllable via
# amixer cset name="TTS Volume" — MQTT bridge is unchanged.
Environment=AUDIO_OUTPUT_DEVICE="alsa/seeed_tts"

# Sound cues
Environment=WAKEUP_SOUND="$SOUNDS_DIR/awake.wav"
Environment=PROCESSING_SOUND="$SOUNDS_DIR/done.wav"

ExecStart=$LVA_DIR/docker-entrypoint.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

info "Enabling and starting linux-voice-assistant..."
sudo systemctl daemon-reload
sudo systemctl enable linux-voice-assistant
sudo systemctl restart linux-voice-assistant
success "Linux Voice Assistant service enabled and started."

# ── Speaker Volume ─────────────────────────────────────────────────────────────
section "Speaker Volume"

# Note: ALC / mic gain settings are NOT applied here. The seeed DKMS module is
# not loaded yet on a fresh install (requires the reboot at the end of this
# script). All ALC settings are applied by smart-display-audio-init.service on
# every boot, after the card has been enumerated. See the Audio Init section.

# The desktop volume slider controls the wrong device. Set the WM8960 speaker
# volume directly via amixer and persist the level to the state file used by
# the volume button service.
if amixer -c seeed2micvoicec controls 2>/dev/null | grep -qi "speaker"; then
    info "Setting WM8960 hardware speaker to 94% (fixed master level)..."
    amixer -c seeed2micvoicec sset 'Speaker' 94% -q
    success "Hardware speaker level set."
else
    warn "Could not find Speaker control on seeed2micvoicec — skipping (card not loaded yet)."
    warn "Audio init service will apply this on first boot."
fi

# Seed default per-stream software volumes if state files don't exist yet.
# TTS at 90%, media at 75% — voice slightly louder than music by default.
[ -f "$CURRENT_HOME/.smart-display-tts-volume"   ] || echo "90" > "$CURRENT_HOME/.smart-display-tts-volume"
[ -f "$CURRENT_HOME/.smart-display-media-volume" ] || echo "75" > "$CURRENT_HOME/.smart-display-media-volume"
success "Default stream volumes seeded (TTS: 90%, Media: 75%)."

# Persist all ALSA mixer settings so they survive reboot.
# alsactl store writes to /var/lib/alsa/asound.state.
sudo alsactl store
success "ALSA mixer state saved to /var/lib/alsa/asound.state."

# ── Audio Initialisation Service ──────────────────────────────────────────────
section "Audio Initialisation Service"

# alsa-restore.service is not designed to be enabled manually — it has no
# [Install] section. More importantly it runs early in boot before the seeed
# DKMS module finishes loading, so the WM8960 resets its registers to hardware
# defaults after the restore. The solution is a dedicated service that:
#   1. Waits (with a retry loop) for the seeed card to actually appear.
#   2. Runs alsactl restore to recover the full mixer state.
#   3. Explicitly re-applies the ALC enumerated controls (these are the most
#      likely to be dropped by alsactl on some kernel/driver combinations).
#   4. Restores speaker volume from the state file maintained by volume-button /
#      the HTTP API, so a volume change made at runtime survives reboot.

info "Creating /usr/local/bin/smart-display-audio-init.sh..."
sudo tee /usr/local/bin/smart-display-audio-init.sh > /dev/null << SCRIPTEOF
#!/bin/bash
# Smart Display audio initialisation.
# Called by smart-display-audio-init.service at every boot.

# Wait up to 30 s for the seeed WM8960 card to be enumerated by the kernel.
# The DKMS module loads via udev and can arrive well after sound.target.
for i in \$(seq 1 30); do
    amixer -c seeed2micvoicec info &>/dev/null && break
    sleep 1
done

# Restore the full ALSA mixer state saved by 'alsactl store'.
/usr/sbin/alsactl restore 2>/dev/null || true

# Set WM8960 hardware speaker to 0 dB (numid=13, value=122 on the 0–127 / -121dB scale).
# This must be re-applied every boot because alsactl restore can be beaten by the
# driver resetting codec registers after enumeration.  Keeping it here rather than
# in asound.state makes the intent explicit and self-documenting.
amixer -c seeed2micvoicec cset numid=13 122,122 -q 2>/dev/null || true

# Re-apply ALC settings explicitly. Enumerated controls (type=ENUMERATED) are
# not reliably restored by alsactl on all kernel/driver versions.
amixer -c seeed2micvoicec cset numid=26 3     -q  # ALC Function → Stereo
amixer -c seeed2micvoicec cset numid=28 11    -q  # ALC Target   → -6 dBFS
amixer -c seeed2micvoicec cset numid=32 2     -q  # ALC Decay    → faster
amixer -c seeed2micvoicec cset numid=1  40,40 -q  # Capture PGA headroom

# Restore per-stream software volumes from state files.
# TTS Volume  → controls LVA/voice playback level (seeed_tts softvol device, used by mpv)
# Media Volume → controls Music Assistant playback level (seeed_media softvol device)
#
# ALSA softvol controls are created lazily — they only exist in the mixer after
# something has opened the PCM device at least once. On a fresh install the
# controls won't be in asound.state yet, so we open each device briefly with a
# tiny silent clip to force the kernel to register the controls before we try
# to set them. Once registered they are saved by alsactl and restored normally
# on all subsequent boots.
if ! amixer -c seeed2micvoicec cget "name=TTS Volume" &>/dev/null; then
    aplay -D seeed_tts   -q -r 22050 -c 1 -f S16_LE /dev/zero &
    sleep 0.3; kill \$! 2>/dev/null; wait
fi
if ! amixer -c seeed2micvoicec cget "name=Media Volume" &>/dev/null; then
    aplay -D seeed_media -q -r 22050 -c 1 -f S16_LE /dev/zero &
    sleep 0.3; kill \$! 2>/dev/null; wait
fi

TTS_VOLFILE="$CURRENT_HOME/.smart-display-tts-volume"
if [ -f "\$TTS_VOLFILE" ]; then
    VOL=\$(cat "\$TTS_VOLFILE")
    amixer -c seeed2micvoicec cset "name=TTS Volume" "\${VOL}%" 2>/dev/null || true
fi

MEDIA_VOLFILE="$CURRENT_HOME/.smart-display-media-volume"
if [ -f "\$MEDIA_VOLFILE" ]; then
    VOL=\$(cat "\$MEDIA_VOLFILE")
    amixer -c seeed2micvoicec cset "name=Media Volume" "\${VOL}%" 2>/dev/null || true
fi
SCRIPTEOF

sudo chmod +x /usr/local/bin/smart-display-audio-init.sh

info "Creating smart-display-audio-init.service..."
sudo tee /etc/systemd/system/smart-display-audio-init.service > /dev/null << 'SVCEOF'
[Unit]
Description=Smart Display Audio Initialisation
After=sound.target
Wants=sound.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/smart-display-audio-init.sh
TimeoutStartSec=60

[Install]
WantedBy=multi-user.target
SVCEOF

sudo systemctl daemon-reload
sudo systemctl enable smart-display-audio-init
sudo systemctl restart smart-display-audio-init
success "Audio init service enabled — volume and ALC will be restored on every boot."

# ── Backlight Permissions ─────────────────────────────────────────────────────
section "Backlight Permissions"

# The DSI display backlight is owned by root. Grant the video group write access
# so the stop-server can adjust brightness without sudo.
# The kernel name "10-0045" is the I2C address of the display controller.
info "Setting up backlight udev rule for display (10-0045)..."
sudo tee /etc/udev/rules.d/99-backlight.rules > /dev/null << 'EOF'
SUBSYSTEM=="backlight", KERNEL=="10-0045", GROUP="video", MODE="0664"
EOF
sudo usermod -a -G video "$CURRENT_USER"
sudo udevadm control --reload-rules && sudo udevadm trigger
success "Backlight permissions configured. (Takes effect on next login/reboot.)"

# ── TTS Stop Server ───────────────────────────────────────────────────────────
section "TTS Stop Server"

STOP_SCRIPT="$CURRENT_HOME/stop-server.py"
info "Installing stop-server.py..."
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
_src=""
for _loc in "$SCRIPT_DIR/stop-server.py" "$(pwd)/stop-server.py"; do
    [ -f "$_loc" ] && _src="$_loc" && break
done
if [ -n "$_src" ]; then
    cp "$_src" "$STOP_SCRIPT"
else
    warn "Could not find stop-server.py — skipping. Copy it manually to $STOP_SCRIPT"
fi

if [ -f "$STOP_SCRIPT" ]; then
    chmod +x "$STOP_SCRIPT"

    info "Creating smart-display-stop.service..."
    sudo tee /etc/systemd/system/smart-display-stop.service > /dev/null << EOF
[Unit]
Description=Smart Display TTS Stop Server
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=$CURRENT_USER
ExecStart=/usr/bin/python3 $STOP_SCRIPT
WorkingDirectory=$CURRENT_HOME
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable smart-display-stop
    sudo systemctl restart smart-display-stop
    success "TTS stop server enabled and started on port 12345."
    echo ""
    HOST="$(hostname).local"
    SLUG=$(echo "$DEVICE_NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '_')
    warn "Add a single rest_command to Home Assistant for stopping TTS:"
    echo ""
    echo "    rest_command:"
    echo "      stop_${SLUG}:"
    echo "        url: \"http://${HOST}:12345/stop\""
    echo "        method: GET"
    echo ""
    info "Volume, brightness, and Stop TTS entities are registered automatically"
    info "via MQTT discovery — no additional YAML needed once the MQTT bridge starts."
fi

# ── sendspin (Music Assistant native player) ──────────────────────────────────
section "sendspin (Music Assistant Native Player)"

# Sendspin is Music Assistant's own playback protocol (introduced in MA 2.7).
# The MA server-side provider is always enabled — no configuration needed in MA.
# The client auto-discovers the MA server via mDNS and registers itself by name.
# Note: Sendspin is currently in technical preview.

info "Installing sendspin dependency (libportaudio2)..."
sudo apt install -y libportaudio2

# Install into an isolated venv to avoid conflicts with Debian system packages
# (sendspin depends on typing_extensions which Debian also owns via apt)
info "Installing sendspin into /opt/sendspin venv..."
[ -d /opt/sendspin ] || sudo python3 -m venv /opt/sendspin
sudo /opt/sendspin/bin/pip install --upgrade sendspin -q

info "Creating sendspin.service..."
sudo tee /etc/systemd/system/sendspin.service > /dev/null << EOF
[Unit]
Description=Sendspin Audio Player (Music Assistant)
Wants=network-online.target smart-display-audio-init.service
After=network-online.target smart-display-audio-init.service

[Service]
Type=simple
User=$CURRENT_USER
ExecStart=/opt/sendspin/bin/sendspin daemon --name "$DEVICE_NAME" --audio-device seeed_media
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable sendspin
sudo systemctl restart sendspin
success "sendspin running — '$DEVICE_NAME' will appear in Music Assistant automatically."
warn "Requires Music Assistant 2.7 or later."

# ── MQTT Bridge (HA device auto-discovery) ────────────────────────────────────
section "MQTT Bridge"

# mqtt-bridge.py connects to your Mosquitto broker and registers the Smart
# Display as a native HA device via MQTT discovery. HA automatically creates:
#   • Voice Volume slider   (controls seeed_tts softvol)
#   • Media Volume slider   (controls seeed_media softvol)
#   • Brightness slider     (controls DSI backlight)
#   • Stop TTS button       (kills in-progress aplay)
# No rest_command or input_number YAML is required — HA picks up the device
# the moment the bridge publishes its discovery payload on first connect.

MQTT_SCRIPT="$CURRENT_HOME/mqtt-bridge.py"
info "Installing mqtt-bridge.py..."
_src=""
for _loc in "$SCRIPT_DIR/mqtt-bridge.py" "$(pwd)/mqtt-bridge.py"; do
    [ -f "$_loc" ] && _src="$_loc" && break
done
if [ -n "$_src" ]; then
    cp "$_src" "$MQTT_SCRIPT"
else
    warn "Could not find mqtt-bridge.py — skipping. Copy it manually to $MQTT_SCRIPT"
fi

if [ -f "$MQTT_SCRIPT" ]; then
    chmod +x "$MQTT_SCRIPT"

    # Write an EnvironmentFile so credentials never appear in ps/journalctl output
    MQTT_ENV_FILE="/etc/smart-display/mqtt.env"
    sudo mkdir -p /etc/smart-display
    sudo tee "$MQTT_ENV_FILE" > /dev/null << ENVEOF
MQTT_HOST=$MQTT_HOST
MQTT_PORT=$MQTT_PORT
MQTT_USERNAME=$MQTT_USERNAME
MQTT_PASSWORD=$MQTT_PASSWORD
DEVICE_NAME=$DEVICE_NAME
DEVICE_ID=$(echo "$DEVICE_NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '_' | tr -cd 'a-z0-9_')
ENVEOF
    sudo chmod 600 "$MQTT_ENV_FILE"

    info "Creating smart-display-mqtt.service..."
    sudo tee /etc/systemd/system/smart-display-mqtt.service > /dev/null << EOF
[Unit]
Description=Smart Display MQTT Bridge
Wants=network-online.target smart-display-audio-init.service
After=network-online.target smart-display-audio-init.service

[Service]
Type=simple
User=$CURRENT_USER
EnvironmentFile=/etc/smart-display/mqtt.env
ExecStart=/usr/bin/python3 $MQTT_SCRIPT
WorkingDirectory=$CURRENT_HOME
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable smart-display-mqtt
    sudo systemctl restart smart-display-mqtt
    success "MQTT bridge enabled. '$DEVICE_NAME' will appear in HA after first connect."
    info "In HA: Settings → Devices & Services → MQTT → check for '$DEVICE_NAME'."
    info "Ensure MQTT discovery is enabled in HA's MQTT integration settings."
fi

# ── Touch Scroll Daemon ───────────────────────────────────────────────────────
section "Touch Scroll Daemon"

# labwc (wlroots) emulates the FT5x06 touchscreen as a pointer device, so
# tapping and dragging work but scroll gestures are never generated.  This
# lightweight daemon monitors the raw touch input node and injects REL_WHEEL
# events via uinput whenever a vertical swipe is detected.  libinput picks up
# the virtual device and labwc forwards the scroll events to Wayland clients.

TOUCH_SCROLL_SCRIPT="$CURRENT_HOME/touch-scroll.py"
info "Installing touch-scroll.py..."
_src=""
for _loc in "$SCRIPT_DIR/touch-scroll.py" "$(pwd)/touch-scroll.py"; do
    [ -f "$_loc" ] && _src="$_loc" && break
done
if [ -n "$_src" ]; then
    cp "$_src" "$TOUCH_SCROLL_SCRIPT"
else
    warn "Could not find touch-scroll.py — skipping. Copy it manually to $TOUCH_SCROLL_SCRIPT"
fi

if [ -f "$TOUCH_SCROLL_SCRIPT" ]; then
    chmod +x "$TOUCH_SCROLL_SCRIPT"

    info "Creating smart-display-touch-scroll.service..."
    sudo tee /etc/systemd/system/smart-display-touch-scroll.service > /dev/null << 'TSEOF'
[Unit]
Description=Smart Display Touch-to-Scroll Daemon
After=systemd-udev-settle.service
Wants=systemd-udev-settle.service

[Service]
Type=simple
ExecStart=/usr/local/bin/touch-scroll.py
Restart=on-failure
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
TSEOF

    sudo cp "$TOUCH_SCROLL_SCRIPT" /usr/local/bin/touch-scroll.py
    sudo chmod +x /usr/local/bin/touch-scroll.py
    sudo systemctl daemon-reload
    sudo systemctl enable smart-display-touch-scroll
    sudo systemctl restart smart-display-touch-scroll
    success "Touch scroll daemon enabled and started."
fi

# ── Kiosk Mode (optional) ─────────────────────────────────────────────────────
if [ -n "$KIOSK_URL" ]; then
    section "Kiosk Mode"

    info "Enabling desktop autologin..."
    sudo raspi-config nonint do_boot_behaviour B4

    info "Disabling console blanking..."
    if ! grep -q "consoleblank=0" /boot/firmware/cmdline.txt; then
        sudo sed -i 's/$/ consoleblank=0/' /boot/firmware/cmdline.txt
        success "consoleblank=0 added to cmdline.txt"
    else
        info "consoleblank=0 already present."
    fi

    # Use labwc's native autostart (shell script) rather than XDG .desktop files.
    # labwc on Raspberry Pi OS Trixie does not reliably process ~/.config/autostart/
    # but always executes ~/.config/labwc/autostart if it is marked executable.
    #
    # --ozone-platform=wayland   → native Wayland rendering (fixes touch/gesture support)
    # --touch-events=enabled     → explicitly enable touch input
    # --disable-pinch            → prevent accidental pinch-zoom on kiosk
    # The curl retry loop waits for HA to be reachable before launching Chromium,
    # preventing a permanent error page if the network is slow to come up.
    info "Creating labwc kiosk autostart..."
    mkdir -p "$CURRENT_HOME/.config/labwc"
    cat > "$CURRENT_HOME/.config/labwc/autostart" << EOF
# Hide the taskbar panel
pkill lxpanel || true
pkill wfbar || true

# Hide the mouse cursor
unclutter --timeout 1 &

# Launch Chromium in kiosk mode.
# Explicitly export Wayland session variables — the subshell used for the
# curl retry loop doesn't always inherit them from the labwc session.
# Waits for Home Assistant to be reachable before opening the browser
# so the display never gets stuck on an error page at boot.
(
  export WAYLAND_DISPLAY="\${WAYLAND_DISPLAY:-wayland-0}"
  export XDG_RUNTIME_DIR="\${XDG_RUNTIME_DIR:-/run/user/\$(id -u)}"
  export XDG_SESSION_TYPE=wayland

  until curl -s --head "$HA_SERVER" > /dev/null 2>&1; do
    sleep 3
  done
  chromium \
    --kiosk \
    --ozone-platform=wayland \
    --touch-events=enabled \
    --noerrdialogs \
    --disable-infobars \
    --no-first-run \
    --disable-session-crashed-bubble \
    --hide-scrollbars \
    --password-store=basic \
    --check-for-update-interval=31536000 \
    --disable-dev-shm-usage \
    --renderer-process-limit=1 \
    --disable-extensions \
    --disable-sync \
    --disable-background-networking \
    --disable-features=TranslateUI \
    --js-flags="--max-old-space-size=192" \
    "$KIOSK_URL"
) &
EOF
    chmod +x "$CURRENT_HOME/.config/labwc/autostart"
    success "labwc kiosk autostart created and marked executable."
else
    info "No kiosk URL provided — skipping kiosk mode setup."
fi

# ── Home Assistant Setup README ───────────────────────────────────────────────
section "Generating Home Assistant Setup README"

cat > "$CURRENT_HOME/smart-display-setup.md" << 'READMEEOF'
# Smart Display — Home Assistant Setup

**Device:** __DEVICENAME__
**Hostname:** `__HOSTNAME__.local`
**HA Server:** `__HASERVER__`

---

## 1. Add Voice Assistant (ESPHome Integration)

In Home Assistant:
1. **Settings → Devices & Services → Add Integration → ESPHome**
2. Host: `__HOSTNAME__.local` | Port: `6053`
3. Open the newly added device → click **"Set Up Voice Assistant"**
4. Select your preferred voice pipeline (Whisper STT + Piper TTS recommended)

---

## 2. MQTT Entities (Auto-Created — No YAML Needed)

The MQTT bridge registers these entities in HA automatically on first connect.
Verify under **Settings → Devices & Services → MQTT → __DEVICENAME__**:

| Entity ID | Purpose |
|-----------|---------|
| `number.__DEVICEID___tts_volume` | Voice / TTS volume (0–100) |
| `number.__DEVICEID___media_volume` | Music Assistant volume (0–100) |
| `number.__DEVICEID___brightness` | Display brightness (0–100) |
| `button.__DEVICEID___stop_tts` | Stop TTS / clear audio |

> **Note:** If entity IDs differ, check the actual names in HA under the device page.
> HA may append `_2`, `_3` etc. on re-registrations.

---

## 3. configuration.yaml

Add to `/config/configuration.yaml` and restart HA:

```yaml
rest_command:
  stop___DEVICEID__:
    url: "http://__HOSTNAME__.local:12345/stop"
    method: GET
```

---

## 4. Lovelace Control Card

In a Lovelace dashboard: **Edit → + Add Card → Manual**, paste:

```yaml
type: entities
title: __DEVICENAME__
entities:
  - entity: number.__DEVICEID___tts_volume
    name: Voice Volume
    icon: mdi:microphone
  - entity: number.__DEVICEID___media_volume
    name: Media Volume
    icon: mdi:music-note
  - entity: number.__DEVICEID___brightness
    name: Brightness
    icon: mdi:brightness-6
  - type: button
    name: Stop TTS
    icon: mdi:stop-circle
    tap_action:
      action: perform-action
      perform_action: rest_command.stop___DEVICEID__
```

---

## 5. Automations

### Dim display at night

```yaml
automation:
  - alias: "__DEVICENAME__ — Dim at night"
    trigger:
      - platform: time
        at: "22:00:00"
    action:
      - action: number.set_value
        target:
          entity_id: number.__DEVICEID___brightness
        data:
          value: 15
```

### Restore brightness in the morning

```yaml
automation:
  - alias: "__DEVICENAME__ — Brighten in morning"
    trigger:
      - platform: time
        at: "07:00:00"
    action:
      - action: number.set_value
        target:
          entity_id: number.__DEVICEID___brightness
        data:
          value: 100
```

### Stop TTS when a media player starts (prevent overlap)

```yaml
automation:
  - alias: "__DEVICENAME__ — Stop TTS on media start"
    trigger:
      - platform: state
        entity_id: media_player.__DEVICEID__  # verify entity in HA
        to: "playing"
    action:
      - action: rest_command.stop___DEVICEID__
```

### Stop TTS from any script or automation

```yaml
action:
  - action: rest_command.stop___DEVICEID__
```

---

## 6. Music Assistant

The device registers itself in Music Assistant 2.7+ as **"__DEVICENAME__"** automatically.
No additional configuration needed — it appears as a player in MA the moment sendspin connects.

---

## Diagnostic Commands

```bash
# Check all service status
sudo systemctl status linux-voice-assistant sendspin smart-display-mqtt

# Live voice assistant logs
journalctl -u linux-voice-assistant -f

# Live MQTT bridge logs
journalctl -u smart-display-mqtt -f

# Test speaker output
aplay -D seeed_tts /usr/share/sounds/alsa/Front_Left.wav

# Check seeed DKMS module (should show current kernel version)
dkms status seeed-voicecard

# Re-run configure script (idempotent — safe to run again to change settings)
cd ~/TunoutDisplay && ./configure.sh
```
READMEEOF

# Substitute runtime values into the README
sed -i \
    -e "s|__DEVICENAME__|$DEVICE_NAME|g" \
    -e "s|__DEVICEID__|$DEVICE_ID|g" \
    -e "s|__HOSTNAME__|$DEVICE_HOSTNAME|g" \
    -e "s|__HASERVER__|$HA_SERVER|g" \
    "$CURRENT_HOME/smart-display-setup.md"

success "README written to ~/smart-display-setup.md"

# ── Done ──────────────────────────────────────────────────────────────────────
section "Done"

echo -e "${GREEN}${BOLD}Configuration complete!${NC}"
echo ""
echo "  ┌─────────────────────────────────────────────────────────────┐"
echo "  │  Next steps                                                 │"
echo "  │                                                             │"
echo "  │  1. Reboot the device (required for driver changes)         │"
echo "  │                                                             │"
echo "  │  2. Add voice assistant to Home Assistant:                  │"
printf "  │     Settings → Devices & Services → Add Integration        │\n"
echo "  │     → ESPHome → 'Set up another instance of ESPHome'        │"
printf "  │     Host: %-20s  Port: 6053              │\n" "$(hostname).local"
echo "  │                                                             │"
echo "  │  3. Click 'Set Up Voice Assistant' to configure pipeline.   │"
echo "  │                                                             │"
echo "  │  4. Music Assistant (2.7+): Sendspin is always-on in MA.    │"
echo "  │     No provider setup needed — your device appears as:     │"
printf "  │     %-57s│\n" "'$DEVICE_NAME'"
echo "  │                                                             │"
echo "  │  5. Say your wake word and test the voice pipeline!          │"
echo "  └─────────────────────────────────────────────────────────────┘"
echo ""
echo "  To check all service status after reboot:"
echo "    sudo systemctl status linux-voice-assistant sendspin smart-display-touch-scroll"
echo ""
echo "  To follow live logs:"
echo "    sudo journalctl -u linux-voice-assistant -f"
echo ""

read -rp "Reboot now? [Y/n] " DO_REBOOT
DO_REBOOT="${DO_REBOOT:-Y}"
if [[ "$DO_REBOOT" =~ ^[Yy]$ ]]; then
    info "Rebooting..."
    sudo reboot
fi
