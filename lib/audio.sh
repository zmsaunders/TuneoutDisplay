# shellcheck shell=bash
# ─────────────────────────────────────────────────────────────────────────────
# lib/audio.sh — stock PipeWire + WirePlumber, output device selection.
#
# v2 has no dmix/softvol stack, no pipewire-alsa ban and no audio-init service.
# Every app (LVA's mpv, sendspin via PortAudio/ALSA) plays into PipeWire, which
# mixes. To make "the" output unambiguous, the Pi's onboard audio (headphone
# jack + HDMI) is switched off whenever a real output is selected, so the
# chosen device is the only sink and WirePlumber picks it as default.
#
# AUDIO_OUTPUT:
#   none       no speaker — display only
#   max98357a  I2S amp, in-tree overlay (to test)
#   wm8960     Keyestudio/Seeed 2-Mic HAT used as a speaker amp only (verify)
#   usb        USB audio — e.g. the voice board's own amp (UNTESTED)
# ─────────────────────────────────────────────────────────────────────────────

PW_SILENT_MIC_CONF="/etc/pipewire/pipewire.conf.d/60-tuneout-silent-mic.conf"
WM8960_UDEV_RULE="/etc/udev/rules.d/91-tuneout-wm8960.rules"
WM8960_MIXER_SCRIPT="/usr/local/sbin/tuneout-wm8960-mixer"
SILENT_MIC_NAME="tuneout-silent-mic"

has_audio() { [ "${AUDIO_OUTPUT:-none}" != "none" ]; }

audio_install() {
    section "Audio (PipeWire → ${AUDIO_OUTPUT})"

    # pipewire-alsa is wanted now: it routes plain-ALSA apps into PipeWire.
    apt_install pipewire pipewire-bin pipewire-pulse pipewire-alsa wireplumber \
                pulseaudio-utils alsa-utils

    # User services (PipeWire) must run at boot without anyone logging in.
    sudo loginctl enable-linger "$CURRENT_USER"
    sudo usermod -aG audio "$CURRENT_USER"

    # ── Boot config: overlay for the chosen output, onboard audio off ────────
    local overlay=""
    case "$AUDIO_OUTPUT" in
        max98357a) overlay="dtoverlay=max98357a${MAX98357A_PARAMS:+,$MAX98357A_PARAMS}" ;;
        wm8960)    overlay="dtoverlay=wm8960-soundcard" ;;
        usb)       untested "USB audio output — relies on the device being the only sink." ;;
    esac
    set_boot_block "$overlay"
    # Headphone jack off; HDMI audio off. Exact-line edits of the stock lines.
    boot_sed 's/^dtparam=audio=on$/dtparam=audio=off/'
    boot_sed 's/^dtoverlay=vc4-kms-v3d$/dtoverlay=vc4-kms-v3d,noaudio/'

    # ── WM8960: unmute the output path every time the card appears ──────────
    if [ "$AUDIO_OUTPUT" = wm8960 ]; then
        _wm8960_install
    else
        remove_file "$WM8960_UDEV_RULE" "$WM8960_MIXER_SCRIPT"
    fi

    # ── Silent virtual mic for the display role ─────────────────────────────
    # LVA opens a microphone and runs wake-word detection even in
    # --output-only mode. With no real mic, PipeWire's default source can be
    # the speaker monitor — LVA would listen to its own playback. A silent
    # virtual source gives it something harmless to read.
    if [ "$ROLE" = display ]; then
        install_file "$PW_SILENT_MIC_CONF" 644 << EOF
# Managed by TuneoutDisplay install.sh — silent mic for LVA output-only mode.
context.objects = [
    {   factory = adapter
        args = {
            factory.name     = support.null-audio-sink
            node.name        = "$SILENT_MIC_NAME"
            node.description = "TuneoutDisplay silent mic"
            media.class      = "Audio/Source/Virtual"
            audio.position   = "MONO"
        }
    }
]
EOF
    else
        remove_file "$PW_SILENT_MIC_CONF"
    fi

    # Restart the user's audio stack so config changes apply now (no-op
    # harm if it wasn't running yet — linger starts it at boot).
    user_systemctl daemon-reload 2>/dev/null || true
    user_systemctl enable -q pipewire pipewire-pulse wireplumber 2>/dev/null || true
    user_systemctl restart pipewire pipewire-pulse wireplumber 2>/dev/null \
        || warn "Couldn't restart PipeWire in this session — it will start at boot."

    if [ "$ROLE" = voice ]; then
        _detect_voice_board
    fi

    # Master volume. The MQTT bridge also re-applies its saved value at start,
    # which covers the first boot after an overlay change.
    sleep 2
    if XDG_RUNTIME_DIR="$RUNTIME_DIR" wpctl get-volume @DEFAULT_AUDIO_SINK@ &>/dev/null; then
        XDG_RUNTIME_DIR="$RUNTIME_DIR" wpctl set-volume @DEFAULT_AUDIO_SINK@ "$(awk "BEGIN{print ${SPEAKER_VOLUME:-80}/100}")"
        success "Speaker volume set to ${SPEAKER_VOLUME:-80}%."
    else
        info "No audio sink yet (normal before the first reboot with a new overlay)."
    fi

    success "Audio configured."
}

audio_remove() {
    section "Audio (none)"
    set_boot_block ""
    boot_sed 's/^dtparam=audio=off$/dtparam=audio=on/'
    boot_sed 's/^dtoverlay=vc4-kms-v3d,noaudio$/dtoverlay=vc4-kms-v3d/'
    remove_file "$PW_SILENT_MIC_CONF" "$WM8960_UDEV_RULE" "$WM8960_MIXER_SCRIPT"
    info "No audio output selected — voice and music services are not installed."
}

_wm8960_install() {
    info "WM8960 HAT as speaker amp — the HAT's mics are ignored."
    warn "Verify on first boot: 'aplay -l' shows wm8960soundcard and 'speaker-test' plays."
    warn "Keyestudio recommends powering the HAT from its own micro-USB when driving a speaker."

    install_file "$WM8960_MIXER_SCRIPT" 755 << 'EOF'
#!/bin/sh
# Managed by TuneoutDisplay install.sh. Run by udev when the WM8960 card
# appears: route the DAC to the output mixers and set the speaker level.
# The in-tree codec powers up with these muted.
CARD=wm8960soundcard
A="/usr/bin/amixer -q -c $CARD"
$A sset 'Left Output Mixer PCM' on
$A sset 'Right Output Mixer PCM' on
$A sset 'Playback' 100%
$A sset 'Speaker' 0dB 2>/dev/null || $A sset 'Speaker' 95%
$A sset 'Speaker AC' 80% 2>/dev/null
$A sset 'Speaker DC' 80% 2>/dev/null
$A sset 'Headphone' 0% 2>/dev/null
exit 0
EOF
    # Runs after 90-alsa-restore.rules, so it wins over any stale saved state.
    install_file "$WM8960_UDEV_RULE" 644 << EOF
# Managed by TuneoutDisplay install.sh
ACTION=="add", SUBSYSTEM=="sound", KERNEL=="controlC*", ATTRS{id}=="wm8960soundcard", RUN+="$WM8960_MIXER_SCRIPT"
EOF
    sudo udevadm control --reload-rules
    # Apply now if the card is already up (re-runs).
    if grep -q wm8960soundcard /proc/asound/cards 2>/dev/null; then
        sudo "$WM8960_MIXER_SCRIPT"
    fi
}

_detect_voice_board() {
    untested "Voice board detection by USB name."
    local found
    found="$(grep -iE 'xvf3800|respeaker' /proc/asound/cards 2>/dev/null | head -1 || true)"
    if [ -n "$found" ]; then
        success "Voice board found: $(echo "$found" | sed 's/^ *//')"
    else
        warn "No reSpeaker XVF3800 / Lite found in /proc/asound/cards. Plug it in and"
        warn "re-run the installer, or check 'arecord -l'."
    fi
    # The boards do echo cancellation on-chip; do NOT add PipeWire's
    # module-echo-cancel on top. Nothing to configure here on purpose.
}
