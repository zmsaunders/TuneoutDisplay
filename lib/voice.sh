# shellcheck shell=bash
# ─────────────────────────────────────────────────────────────────────────────
# lib/voice.sh — Linux Voice Assistant (ESPHome protocol), pinned to a tag.
#
#   display role + audio → LVA --output-only: an HA announcement/TTS target
#                          (media player entity), reading a silent virtual mic.
#   voice role           → LVA full mode. UNTESTED until a USB voice board is
#                          in hand.
#
# Wake word off (voice role): LVA has no switch for it — an empty wake-word
# list falls back to the default model. We apply a one-line, env-controlled
# patch (TUNEOUT_WAKE_WORD=0 skips wake-word activation) so button / HA
# "start listening" still works. Preferred long-term fix is upstream.
# ─────────────────────────────────────────────────────────────────────────────

LVA_DIR="$CURRENT_HOME/lva"
LVA_REPO="https://github.com/OHF-Voice/linux-voice-assistant"
LVA_ENV="$CONF_DIR/lva.env"
LVA_STAMP="$LVA_DIR/.tuneout-installed-version"
LVA_PATCH_FILE="linux_voice_assistant/__main__.py"
LVA_PATCH_FROM='if activated and not state.muted:'
LVA_PATCH_TO='if activated and not state.muted and __import__("os").environ.get("TUNEOUT_WAKE_WORD", "1") != "0":  # tuneout-patch'
LVA_PERIPHERAL_PORT=6055

voice_install() {
    local mode="$1"   # full | output-only
    section "Linux Voice Assistant ($mode, ${LVA_VERSION})"
    [ "$mode" = full ] && untested "LVA full voice mode (needs a USB voice board)."

    apt_install git python3-venv python3-dev build-essential libmpv-dev \
                pulseaudio-utils alsa-utils

    # Stop first: a running LVA holds the venv's python open ("Text file busy").
    sudo systemctl stop linux-voice-assistant 2>/dev/null || true

    # ── Source at the pinned tag ────────────────────────────────────────────
    if [ -d "$LVA_DIR/.git" ]; then
        git -C "$LVA_DIR" fetch -q --tags origin
    else
        git clone -q "$LVA_REPO" "$LVA_DIR"
    fi
    # -f discards our previous patch so the tree matches the tag exactly.
    git -C "$LVA_DIR" checkout -q -f "$LVA_VERSION" \
        || die "LVA tag '$LVA_VERSION' not found. Set LVA_VERSION in $SETTINGS_FILE."
    chmod +x "$LVA_DIR/docker-entrypoint.sh"

    # ── Python env (slow: compiles wheels) — only when the version changed ──
    if [ ! -x "$LVA_DIR/.venv/bin/python" ] || [ "$(cat "$LVA_STAMP" 2>/dev/null)" != "$LVA_VERSION" ]; then
        info "Building LVA environment (several minutes on a Pi 4)..."
        (cd "$LVA_DIR" && script/setup --cxxflags="-O1 -g0" --makeflags="-j2")
        echo "$LVA_VERSION" > "$LVA_STAMP"
    else
        info "LVA $LVA_VERSION environment already built."
    fi

    # ── Wake-word-off patch (voice role only) ───────────────────────────────
    if [ "$mode" = full ] && [ "${WAKE_WORD_ENABLED:-yes}" = no ]; then
        untested "Wake word disabled via local LVA patch."
        if grep -qF "$LVA_PATCH_FROM" "$LVA_DIR/$LVA_PATCH_FILE"; then
            # Literal replace (python avoids sed escaping of the quotes/parens).
            python3 - "$LVA_DIR/$LVA_PATCH_FILE" "$LVA_PATCH_FROM" "$LVA_PATCH_TO" << 'PY'
import sys
path, old, new = sys.argv[1:4]
src = open(path).read()
open(path, "w").write(src.replace(old, new, 1))
PY
            success "Wake-word-off patch applied."
        else
            warn "LVA $LVA_VERSION changed the wake-word code — patch not applied;"
            warn "the wake word stays ON. Update LVA_PATCH_FROM in lib/voice.sh."
        fi
    fi

    # ── Service config ──────────────────────────────────────────────────────
    {
        env_line CLIENT_NAME "$DEVICE_NAME"
        env_line PREFERENCES_FILE "$LVA_DIR/preferences.json"
        env_line PULSE_SERVER "unix:$RUNTIME_DIR/pulse/native"
        env_line XDG_RUNTIME_DIR "$RUNTIME_DIR"
        env_line PULSE_COOKIE "$LVA_DIR/tmp_pulse_cookie"
        env_line WAKE_MODEL "${WAKE_WORD:-okay_nabu}"
        # Peripheral API (push-to-talk etc.) — localhost only.
        env_line PERIPHERAL_HOST "127.0.0.1"
        env_line PERIPHERAL_PORT "$LVA_PERIPHERAL_PORT"
        if [ "$mode" = output-only ]; then
            env_line ENABLE_OUTPUT_ONLY "1"
            env_line AUDIO_INPUT_DEVICE "$SILENT_MIC_NAME"
        fi
        if [ "$mode" = full ] && [ "${WAKE_WORD_ENABLED:-yes}" = no ]; then
            env_line TUNEOUT_WAKE_WORD "0"
        fi
    } | install_file "$LVA_ENV" 644

    install_file /etc/systemd/system/linux-voice-assistant.service 644 << EOF
# Managed by TuneoutDisplay install.sh
[Unit]
Description=Linux Voice Assistant ($mode)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$CURRENT_USER
WorkingDirectory=$LVA_DIR
Environment=PATH=$LVA_DIR/.venv/bin:/usr/bin:/bin
EnvironmentFile=$LVA_ENV
# The entrypoint waits up to 30 s for PipeWire-Pulse, then maps env → flags.
ExecStart=$LVA_DIR/docker-entrypoint.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    enable_restart linux-voice-assistant
    success "LVA running ($mode). Add it in HA: ESPHome → $(hostname).local, port 6053."
}

voice_remove() {
    if unit_exists linux-voice-assistant; then
        section "Linux Voice Assistant (not used by this role)"
        disable_unit linux-voice-assistant /etc/systemd/system/linux-voice-assistant.service
        remove_file "$LVA_ENV"
        sudo systemctl daemon-reload
    fi
}
