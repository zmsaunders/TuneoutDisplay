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
BLANK_CURSOR_THEME="tuneout-blank"
BLANK_CURSOR_DIR="/usr/share/icons/$BLANK_CURSOR_THEME"

# Every cursor name cage (wlroots) or Chromium may ask for: CSS names plus
# the legacy X11 aliases. All point at one fully transparent image.
BLANK_CURSOR_NAMES=(
    default left_ptr arrow top_left_arrow pointer hand hand1 hand2 pointing_hand
    text xterm ibeam vertical-text wait watch progress left_ptr_watch half-busy
    help question_arrow whats_this crosshair cross tcross cell plus move fleur
    all-scroll grab grabbing openhand closedhand dnd-move dnd-copy dnd-link dnd-none
    copy alias context-menu not-allowed no-drop crossed_circle forbidden circle
    col-resize row-resize sb_h_double_arrow sb_v_double_arrow split_h split_v
    n-resize s-resize e-resize w-resize ne-resize nw-resize se-resize sw-resize
    ew-resize ns-resize nesw-resize nwse-resize size_hor size_ver size_bdiag size_fdiag
    top_side bottom_side left_side right_side top_left_corner top_right_corner
    bottom_left_corner bottom_right_corner zoom-in zoom-out none
)

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
    } | install_file "$KIOSK_ENV" 644
    local changed=$FILE_CHANGED

    install_file "$KIOSK_LAUNCHER" 755 < "$SCRIPT_DIR/lib/files/tuneout-kiosk"
    changed=$((changed | FILE_CHANGED))

    _install_blank_cursor
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
# Invisible cursor theme (see _install_blank_cursor).
Environment=XCURSOR_THEME=$BLANK_CURSOR_THEME
Environment=XCURSOR_SIZE=24
EnvironmentFile=$KIOSK_ENV
# -d: no client-side decorations. cage hides the cursor when there's no mouse.
ExecStart=/usr/bin/cage -d -- $KIOSK_LAUNCHER
Restart=always
RestartSec=3

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

# ── Invisible cursor ─────────────────────────────────────────────────────────
# cage is meant to hide the cursor when there's no mouse, but on the Pi 4 +
# DSI touchscreen a cursor still sat mid-screen (cage centres it at start).
# Rather than chase which layer draws it, give both cage (wlroots) and
# Chromium a cursor theme whose every image is transparent, and make it the
# kiosk user's default theme. Sets FILE_CHANGED=1 if anything changed.
_install_blank_cursor() {
    local any=0 tmp name
    tmp="$(mktemp)"
    # One 24x24 fully transparent Xcursor image (Xcursor file format:
    # header, one TOC entry, one image chunk of ARGB pixels).
    python3 - "$tmp" << 'PY'
import struct, sys
size = 24
pixels = b"\0" * (size * size * 4)
img = struct.pack("<9I", 36, 0xFFFD0002, size, 1, size, size, 0, 0, 0) + pixels
toc = struct.pack("<3I", 0xFFFD0002, size, 16 + 12)
with open(sys.argv[1], "wb") as f:
    f.write(b"Xcur" + struct.pack("<3I", 16, 0x10000, 1) + toc + img)
PY
    install_file "$BLANK_CURSOR_DIR/cursors/default" 644 < "$tmp"
    any=$((any | FILE_CHANGED))
    rm -f "$tmp"

    for name in "${BLANK_CURSOR_NAMES[@]}"; do
        [ "$name" = default ] && continue
        if [ "$(readlink "$BLANK_CURSOR_DIR/cursors/$name" 2>/dev/null)" != default ]; then
            sudo ln -sfn default "$BLANK_CURSOR_DIR/cursors/$name"
            any=1
        fi
    done

    printf '[Icon Theme]\nName=TuneoutDisplay blank cursor\nComment=Fully transparent cursors for the kiosk\n' \
        | install_file "$BLANK_CURSOR_DIR/index.theme" 644
    any=$((any | FILE_CHANGED))

    # ~/.icons/default is searched before system themes by both wlroots and
    # Chromium, so this covers code paths that ignore XCURSOR_THEME.
    mkdir -p "$CURRENT_HOME/.icons/default"   # user-owned, not via sudo
    printf '[Icon Theme]\nInherits=%s\n' "$BLANK_CURSOR_THEME" \
        | install_file "$CURRENT_HOME/.icons/default/index.theme" 644 "$CURRENT_USER:$CURRENT_USER"
    any=$((any | FILE_CHANGED))

    FILE_CHANGED=$any
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
