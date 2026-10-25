# shellcheck shell=bash
# ─────────────────────────────────────────────────────────────────────────────
# lib/cleanup.sh — remove leftovers from v1 (and early v2) so a device can be
# re-run in place.
# On a fresh Lite image every step here is a no-op.
#
# Deliberately NOT touched: the seeed-voicecard DKMS module itself (removing a
# kernel module mid-run is riskier than leaving it; re-imaging is the clean
# path) — we only warn.
# ─────────────────────────────────────────────────────────────────────────────

legacy_cleanup() {
    local found=0

    # Services v2 no longer uses.
    for svc in smart-display-audio-init smart-display-stop; do
        if unit_exists "$svc"; then
            found=1
            disable_unit "$svc" "/etc/systemd/system/$svc.service"
        fi
    done
    remove_file /usr/local/bin/smart-display-audio-init.sh /usr/local/bin/stop-server.py

    # Caldera (dropped in v2) — a systemd --user service.
    if user_systemctl list-unit-files caldera-music.service --no-legend 2>/dev/null | grep -q caldera; then
        found=1
        user_systemctl disable --now caldera-music 2>/dev/null || true
        rm -rf "$CURRENT_HOME/.config/systemd/user/caldera-music.service.d"
        info "Disabled Caldera (not part of v2). ~/caldera-music left in place."
    fi
    remove_file "$CONF_DIR/caldera-asound.conf"

    # v1 ALSA dmix/softvol stack and the WirePlumber rule that hid the seeed output.
    if [ -f /etc/asound.conf ] && grep -q seeed_dmix /etc/asound.conf; then
        found=1
        remove_file /etc/asound.conf
    fi
    remove_file /etc/wireplumber/wireplumber.conf.d/50-seeed-disable-output.conf

    # mpv forced to ALSA (v2 lets mpv use PipeWire).
    if [ -f "$CURRENT_HOME/.config/mpv/mpv.conf" ] && grep -qx 'ao=alsa' "$CURRENT_HOME/.config/mpv/mpv.conf"; then
        found=1
        rm -f "$CURRENT_HOME/.config/mpv/mpv.conf"
        info "Removed ~/.config/mpv/mpv.conf (ao=alsa)."
    fi

    # labwc kiosk autostart (v2 uses cage).
    if [ -f "$CURRENT_HOME/.config/labwc/autostart" ] && grep -q 'remote-debugging-port' "$CURRENT_HOME/.config/labwc/autostart"; then
        found=1
        rm -f "$CURRENT_HOME/.config/labwc/autostart"
        info "Removed v1 labwc kiosk autostart."
    fi

    # Old copies of scripts and state files.
    rm -f "$CURRENT_HOME/mqtt-bridge.py" "$CURRENT_HOME/touch-scroll.py" "$CURRENT_HOME/mic.sh" \
          "$CURRENT_HOME/.smart-display-tts-volume" "$CURRENT_HOME/.smart-display-media-volume" \
          "$CURRENT_HOME/.smart-display-mic-gain"

    # Early-v2 invisible cursor theme — superseded by the HDMI-CEC udev rule.
    if [ -d /usr/share/icons/tuneout-blank ]; then
        found=1
        sudo rm -rf /usr/share/icons/tuneout-blank
        info "Removed the unused tuneout-blank cursor theme."
    fi
    if [ -f "$CURRENT_HOME/.icons/default/index.theme" ] \
       && grep -qx 'Inherits=tuneout-blank' "$CURRENT_HOME/.icons/default/index.theme"; then
        found=1
        rm -f "$CURRENT_HOME/.icons/default/index.theme"
        rmdir "$CURRENT_HOME/.icons/default" "$CURRENT_HOME/.icons" 2>/dev/null || true
    fi

    if dkms status seeed-voicecard 2>/dev/null | grep -q seeed; then
        warn "The v1 seeed-voicecard DKMS module is still installed. v2 doesn't use it,"
        warn "and it may fail to build on new kernels. Re-imaging with Lite is the clean fix;"
        warn "or remove it: sudo dkms remove seeed-voicecard/0.3 --all"
    fi

    [ "$found" = 1 ] && success "Old leftovers cleaned up."
    return 0
}
