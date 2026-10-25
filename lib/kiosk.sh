# shellcheck shell=bash
# ─────────────────────────────────────────────────────────────────────────────
# lib/kiosk.sh — cage (Wayland kiosk compositor) + Chromium on tty1.
#
# No desktop, no labwc. A system service opens a logind session on tty1 via
# PAM, starts cage, and cage runs a launcher that waits for Home Assistant and
# then execs Chromium. If Chromium exits, cage exits and systemd restarts it.
# ─────────────────────────────────────────────────────────────────────────────

KIOSK_SERVICE="tuneout-kiosk"
KIOSK_LAUNCHER="/usr/local/bin/tuneout-kiosk"
KIOSK_ENV="$CONF_DIR/kiosk.env"
KIOSK_PROFILE_DIR="$CURRENT_HOME/.local/share/tuneout-kiosk/chromium"
CDP_PORT=9222

kiosk_install() {
    section "Kiosk (cage + Chromium)"

    apt_install cage curl
    # Raspberry Pi OS Trixie ships "chromium"; older images used "chromium-browser".
    if ! apt_install chromium 2>/dev/null; then
        apt_install chromium-browser
    fi

    # A desktop display manager would fight cage for tty1/seat0.
    if unit_exists lightdm && systemctl is-enabled -q lightdm 2>/dev/null; then
        warn "A desktop (lightdm) is enabled — this build expects Raspberry Pi OS Lite."
        warn "Disabling lightdm and booting to console so the kiosk owns the screen."
        sudo systemctl disable -q lightdm || true
        sudo systemctl set-default multi-user.target
        REBOOT_REQUIRED=1
    fi

    # Kiosk user needs DRM, GPU and input access (logind also grants ACLs for
    # the active session; these groups are the belt to that brace).
    sudo usermod -aG video,render,input "$CURRENT_USER"

    # Keep the console from blanking before cage takes over.
    if [ -f "$BOOT_CMDLINE" ] && ! grep -q "consoleblank=0" "$BOOT_CMDLINE"; then
        sudo sed -i 's/$/ consoleblank=0/' "$BOOT_CMDLINE"
        REBOOT_REQUIRED=1
    fi

    {
        env_line KIOSK_URL "$KIOSK_URL"
        env_line HA_ORIGIN "$(url_origin "$KIOSK_URL")"
        env_line CDP_PORT "$CDP_PORT"
        env_line PROFILE_DIR "$KIOSK_PROFILE_DIR"
        env_line CHROMIUM_EXTRA_FLAGS "${CHROMIUM_EXTRA_FLAGS:-}"
        env_line KIOSK_THEME "${KIOSK_THEME:-dark}"
    } | install_file "$KIOSK_ENV" 644
    local changed=$FILE_CHANGED

    install_file "$KIOSK_LAUNCHER" 755 < "$SCRIPT_DIR/lib/files/tuneout-kiosk"
    changed=$((changed | FILE_CHANGED))

    _ignore_hdmi_cec_input
    changed=$((changed | FILE_CHANGED))

    # PAM stack for the kiosk session: pam_systemd registers a logind session
    # on seat0/tty1, which is what lets cage open the display and input devices.
    install_file /etc/pam.d/tuneout-kiosk 644 << 'EOF'
# TuneoutDisplay kiosk session (cage). Managed by install.sh.
auth     required pam_unix.so nullok
account  required pam_unix.so
session  required pam_unix.so
session  required pam_systemd.so
EOF

    install_file "/etc/systemd/system/$KIOSK_SERVICE.service" 644 << EOF
# Managed by TuneoutDisplay install.sh
[Unit]
Description=TuneoutDisplay kiosk (cage + Chromium on tty1)
After=systemd-user-sessions.service network-online.target dbus.socket systemd-logind.service getty@tty1.service
Wants=network-online.target dbus.socket systemd-logind.service
Conflicts=getty@tty1.service
ConditionPathExists=/dev/tty1

[Service]
Type=simple
User=$CURRENT_USER
PAMName=tuneout-kiosk
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
TTYVTDisallocate=yes
StandardInput=tty-fail
StandardOutput=journal
StandardError=journal
UtmpIdentifier=tty1
UtmpMode=user
# Let cage start even if the touchscreen hasn't enumerated yet.
Environment=WLR_LIBINPUT_NO_DEVICES=1
EnvironmentFile=$KIOSK_ENV
# -d: no client-side decorations. cage hides the cursor when there's no mouse.
ExecStart=/usr/bin/cage -d -- $KIOSK_LAUNCHER
Restart=always
RestartSec=3
# Chromium can be slow to quit; don't let a restart hang for the 90 s default.
TimeoutStopSec=10

[Install]
WantedBy=multi-user.target
EOF
    changed=$((changed | FILE_CHANGED))

    sudo systemctl daemon-reload
    sudo systemctl enable -q "$KIOSK_SERVICE"
    # Only bounce the screen on re-runs when something actually changed.
    if [ "$changed" = 1 ] || ! systemctl is-active -q "$KIOSK_SERVICE"; then
        sudo systemctl restart "$KIOSK_SERVICE"
    fi
    success "Kiosk enabled → $KIOSK_URL"
}

# ── Ignore HDMI-CEC "remotes" as input ───────────────────────────────────────
# The Pi registers an input device per HDMI port (vc4-hdmi-0/1) for CEC remote
# control, even with nothing plugged in. The kernel's remote-control layer
# advertises relative X/Y on every remote, so libinput treats them as pointing
# devices. cage then gives the seat a pointer, Chromium believes a mouse is
# attached, and draws its cursor mid-screen. Telling libinput to ignore them
# leaves the touchscreen as the only input. Sets FILE_CHANGED.
CEC_INPUT_RULE="/etc/udev/rules.d/90-tuneout-ignore-hdmi-cec-input.rules"
_ignore_hdmi_cec_input() {
    install_file "$CEC_INPUT_RULE" 644 << 'EOF'
# Managed by TuneoutDisplay install.sh — HDMI-CEC remotes are not a mouse.
ACTION=="add|change", SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="vc4-hdmi*", ENV{LIBINPUT_IGNORE_DEVICE}="1"
EOF
    if [ "$FILE_CHANGED" = 1 ]; then
        sudo udevadm control --reload-rules
        sudo udevadm trigger --subsystem-match=input --action=change
    fi
}

# ── Touch-scroll fallback (off by default) ───────────────────────────────────
# v1 needed touch-scroll.py because labwc turned touch into pointer events.
# cage passes real touch to Chromium, which scrolls natively — so this is only
# a fallback (TOUCH_SCROLL=yes in the settings file). Caveat: its virtual wheel
# device counts as a pointer, so cage will show a cursor while it's enabled.
touch_scroll_apply() {
    local unit=/etc/systemd/system/smart-display-touch-scroll.service
    if [ "${TOUCH_SCROLL:-no}" = yes ]; then
        section "Touch-scroll fallback"
        apt_install python3-evdev
        install_file /usr/local/bin/touch-scroll.py 755 < "$SCRIPT_DIR/touch-scroll.py"
        install_file "$unit" 644 << 'UNIT'
# Managed by TuneoutDisplay install.sh
[Unit]
Description=TuneoutDisplay touch-to-scroll fallback
After=systemd-udev-settle.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/touch-scroll.py
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
        sudo systemctl daemon-reload
        enable_restart smart-display-touch-scroll
        success "Touch-scroll fallback enabled."
    elif unit_exists smart-display-touch-scroll; then
        disable_unit smart-display-touch-scroll "$unit"
        remove_file /usr/local/bin/touch-scroll.py
        sudo systemctl daemon-reload
    fi
}
