# shellcheck shell=bash
# ─────────────────────────────────────────────────────────────────────────────
# lib/music.sh — sendspin, Music Assistant's native player (MA 2.7+).
#
# Plays into PipeWire (ALSA "default" → pipewire-alsa). --hardware-volume false
# keeps MA's volume on sendspin's own stream instead of the system master, so
# music volume never moves TTS volume.
# ─────────────────────────────────────────────────────────────────────────────

SENDSPIN_VENV="/opt/sendspin"
DEVICE_ENV="$CONF_DIR/device.env"

music_install() {
    section "Music Assistant player (sendspin ${SENDSPIN_VERSION})"

    apt_install python3-venv libportaudio2

    [ -x "$SENDSPIN_VENV/bin/python" ] || sudo python3 -m venv "$SENDSPIN_VENV"
    local have
    # `pip show` exits 1 when not installed — don't let pipefail abort the run.
    have="$("$SENDSPIN_VENV/bin/pip" show sendspin 2>/dev/null | awk '/^Version:/{print $2}' || true)"
    if [ "$have" != "$SENDSPIN_VERSION" ]; then
        info "Installing sendspin $SENDSPIN_VERSION (had: ${have:-none})..."
        sudo "$SENDSPIN_VENV/bin/pip" install -q "sendspin==$SENDSPIN_VERSION"
    fi

    env_line DEVICE_NAME "$DEVICE_NAME" | install_file "$DEVICE_ENV" 644

    install_file /etc/systemd/system/sendspin.service 644 << EOF
# Managed by TuneoutDisplay install.sh
[Unit]
Description=Sendspin player for Music Assistant
After=network-online.target sound.target
Wants=network-online.target

[Service]
Type=simple
User=$CURRENT_USER
Environment=XDG_RUNTIME_DIR=$RUNTIME_DIR
EnvironmentFile=$DEVICE_ENV
# \${DEVICE_NAME} (braced) is passed as one argument even with spaces.
ExecStart=$SENDSPIN_VENV/bin/sendspin daemon --name \${DEVICE_NAME} --hardware-volume false --disable-mpris
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    enable_restart sendspin
    success "sendspin running — '$DEVICE_NAME' appears in Music Assistant automatically."
}

music_remove() {
    if unit_exists sendspin; then
        section "Music Assistant player (disabled)"
        disable_unit sendspin /etc/systemd/system/sendspin.service
        sudo systemctl daemon-reload
    fi
}
