# shellcheck shell=bash
# ─────────────────────────────────────────────────────────────────────────────
# lib/mqtt.sh — MQTT discovery bridge (always installed).
#
# FEATURES tells the bridge which entities to register; entities for features
# this role doesn't have (and v1's retired entities) are removed from HA.
# ─────────────────────────────────────────────────────────────────────────────

MQTT_ENV="$CONF_DIR/mqtt.env"
BRIDGE_PATH="$LIB_INSTALL_DIR/mqtt-bridge.py"
BACKLIGHT_RULE="/etc/udev/rules.d/99-tuneout-backlight.rules"

mqtt_install() {
    section "MQTT bridge"

    apt_install python3-paho-mqtt python3-websocket

    # Backlight: let the video group write brightness / bl_power on whatever
    # backlight device the panel exposes (no hard-coded 10-0045).
    install_file "$BACKLIGHT_RULE" 644 << 'EOF'
# Managed by TuneoutDisplay install.sh
ACTION=="add", SUBSYSTEM=="backlight", RUN+="/bin/chgrp video /sys%p/brightness /sys%p/bl_power", RUN+="/bin/chmod g+w /sys%p/brightness /sys%p/bl_power"
EOF
    remove_file /etc/udev/rules.d/99-backlight.rules   # v1 rule
    sudo usermod -aG video "$CURRENT_USER"
    sudo udevadm control --reload-rules
    sudo udevadm trigger --subsystem-match=backlight --action=add

    local features="brightness,screen,dashboard"
    has_audio && features="$features,speaker_volume"
    [ "$ROLE" = voice ] && features="$features,talk"

    install_file "$BRIDGE_PATH" 755 < "$SCRIPT_DIR/mqtt-bridge.py"
    local changed=$FILE_CHANGED

    {
        env_line MQTT_HOST "$MQTT_HOST"
        env_line MQTT_PORT "$MQTT_PORT"
        env_line MQTT_USERNAME "$MQTT_USERNAME"
        env_line MQTT_PASSWORD "$MQTT_PASSWORD"
        env_line DEVICE_NAME "$DEVICE_NAME"
        env_line DEVICE_ID "$DEVICE_ID"
        env_line DASHBOARD_URL "$KIOSK_URL"
        env_line CDP_PORT "$CDP_PORT"
        env_line FEATURES "$features"
        env_line DEFAULT_SPEAKER_VOLUME "${SPEAKER_VOLUME:-80}"
        env_line PERIPHERAL_PORT "$LVA_PERIPHERAL_PORT"
    } | install_file "$MQTT_ENV" 600
    changed=$((changed | FILE_CHANGED))

    install_file /etc/systemd/system/smart-display-mqtt.service 644 << EOF
# Managed by TuneoutDisplay install.sh
[Unit]
Description=TuneoutDisplay MQTT bridge
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$CURRENT_USER
# wpctl (speaker volume) talks to this user's PipeWire.
Environment=XDG_RUNTIME_DIR=$RUNTIME_DIR
Environment=PYTHONUNBUFFERED=1
EnvironmentFile=$MQTT_ENV
ExecStart=/usr/bin/python3 $BRIDGE_PATH
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    changed=$((changed | FILE_CHANGED))

    sudo systemctl daemon-reload
    sudo systemctl enable -q smart-display-mqtt
    if [ "$changed" = 1 ] || ! systemctl is-active -q smart-display-mqtt; then
        sudo systemctl restart smart-display-mqtt
    fi
    success "MQTT bridge running (entities: $features)."
}
