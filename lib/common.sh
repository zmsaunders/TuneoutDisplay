# shellcheck shell=bash
# ─────────────────────────────────────────────────────────────────────────────
# lib/common.sh — logging, settings, prompts and idempotency helpers.
# Sourced by install.sh. Expects SCRIPT_DIR to be set by the caller.
# ─────────────────────────────────────────────────────────────────────────────

# ── Logging ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; MAGENTA='\033[1;35m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${BLUE}▶${NC}  $*"; }
success() { echo -e "${GREEN}✔${NC}  $*"; }
warn()    { echo -e "${YELLOW}⚠${NC}  $*"; }
die()     { echo -e "${RED}✘  ERROR:${NC} $*" >&2; exit 1; }
section() { echo -e "\n${BOLD}${BLUE}━━━  $*  ━━━${NC}\n"; }
untested(){ echo -e "${MAGENTA}⚑  UNTESTED:${NC} $*"; }

# ── Identity ─────────────────────────────────────────────────────────────────
CURRENT_USER="$(id -un)"
CURRENT_HOME="$HOME"
USER_ID="$(id -u)"
RUNTIME_DIR="/run/user/$USER_ID"
CONF_DIR="/etc/smart-display"
LIB_INSTALL_DIR="/usr/local/lib/tuneout-display"
BOOT_CONFIG="/boot/firmware/config.txt"
BOOT_CMDLINE="/boot/firmware/cmdline.txt"

# Set to 1 by any step that changes something only a reboot applies.
REBOOT_REQUIRED=0

# ── Settings ─────────────────────────────────────────────────────────────────
SETTINGS_FILE="${SETTINGS_FILE:-$CURRENT_HOME/.smart-display-settings}"

# Every persisted setting. Order is the order they're written to the file.
SETTINGS_KEYS=(
    ROLE DEVICE_NAME KIOSK_URL
    AUDIO_OUTPUT MUSIC_ASSISTANT SPEAKER_VOLUME
    WAKE_WORD_ENABLED WAKE_WORD
    MQTT_HOST MQTT_PORT MQTT_USERNAME MQTT_PASSWORD
    TOUCH_SCROLL CHROMIUM_EXTRA_FLAGS MAX98357A_PARAMS
    LVA_VERSION SENDSPIN_VERSION ALLOW_UNTESTED
)

load_settings() {
    if [ -f "$SETTINGS_FILE" ]; then
        # shellcheck disable=SC1090
        source "$SETTINGS_FILE"
        return 0
    fi
    return 1
}

save_settings() {
    local key tmp
    tmp="$(mktemp)"
    {
        echo "# TuneoutDisplay settings — written by install.sh. Safe to edit;"
        echo "# 'install.sh --non-interactive' reads this file as-is."
        for key in "${SETTINGS_KEYS[@]}"; do
            # %q quotes safely for re-sourcing (spaces, quotes, \$ in passwords).
            printf '%s=%q\n' "$key" "${!key-}"
        done
    } > "$tmp"
    install -m 600 "$tmp" "$SETTINGS_FILE"
    rm -f "$tmp"
}

# ── Prompts ──────────────────────────────────────────────────────────────────
# All prompts honour NON_INTERACTIVE=1: they keep the current value (from the
# settings file) or fall back to the default, and never block.

# ask VAR "Label" "default"
ask() {
    local var="$1" label="$2" def="${!1:-$3}" in
    if [ "${NON_INTERACTIVE:-0}" = 1 ]; then
        printf -v "$var" '%s' "$def"; return
    fi
    read -rp "  $label [${def:-none}]: " in
    # "none" clears an optional value; ENTER keeps the default.
    if [ "$in" = "none" ]; then in=""; elif [ -z "$in" ]; then in="$def"; fi
    printf -v "$var" '%s' "$in"
}

# ask_choice VAR "Label" "default" choice1 choice2 ...
ask_choice() {
    local var="$1" label="$2" def="${!1:-$3}" in c
    shift 3
    while true; do
        if [ "${NON_INTERACTIVE:-0}" = 1 ]; then
            in="$def"
        else
            read -rp "  $label [$(IFS=/; echo "$*")] [${def}]: " in
            in="${in:-$def}"
        fi
        for c in "$@"; do
            if [ "$in" = "$c" ]; then printf -v "$var" '%s' "$in"; return; fi
        done
        [ "${NON_INTERACTIVE:-0}" = 1 ] && die "$var='$in' is not one of: $*"
        warn "Enter one of: $*"
    done
}

# ask_yesno VAR "Label" "yes|no"
ask_yesno() {
    local var="$1" label="$2" def="${!1:-$3}" in
    while true; do
        if [ "${NON_INTERACTIVE:-0}" = 1 ]; then
            in="$def"
        else
            read -rp "  $label [y/n] [${def}]: " in
            in="${in:-$def}"
        fi
        case "${in,,}" in
            y|yes) printf -v "$var" yes; return ;;
            n|no)  printf -v "$var" no;  return ;;
        esac
        [ "${NON_INTERACTIVE:-0}" = 1 ] && die "$var='$in' must be yes or no"
        warn "Enter y or n"
    done
}

# ask_secret VAR "Label" — ENTER keeps a saved value.
ask_secret() {
    local var="$1" label="$2" in
    [ "${NON_INTERACTIVE:-0}" = 1 ] && return
    if [ -n "${!var-}" ]; then
        read -rsp "  $label (ENTER keeps saved): " in; echo
        # Must be an if: a bare `[ -n "$in" ] && …` as the function's last
        # command returns 1 on ENTER, and set -e then kills the installer.
        if [ -n "$in" ]; then printf -v "$var" '%s' "$in"; fi
    else
        read -rsp "  $label: " in; echo
        printf -v "$var" '%s' "$in"
    fi
}

# ── Files ────────────────────────────────────────────────────────────────────
# install_file DEST MODE [OWNER]  — content on stdin. Writes only when the
# content differs, so re-runs don't touch mtimes. Sets FILE_CHANGED=1/0.
FILE_CHANGED=0
install_file() {
    local dest="$1" mode="$2" owner="${3:-root:root}" tmp
    tmp="$(mktemp)"
    cat > "$tmp"
    if sudo test -f "$dest" && sudo cmp -s "$tmp" "$dest"; then
        FILE_CHANGED=0
    else
        sudo mkdir -p "$(dirname "$dest")"
        sudo install -m "$mode" -o "${owner%%:*}" -g "${owner##*:}" "$tmp" "$dest"
        FILE_CHANGED=1
    fi
    rm -f "$tmp"
}

# remove_file PATH... — removes if present (sudo).
remove_file() {
    local f
    for f in "$@"; do
        if sudo test -e "$f"; then sudo rm -f "$f"; info "Removed $f"; fi
    done
}

# env_line KEY VALUE — one line for a systemd EnvironmentFile, double-quoted
# with backslashes and quotes escaped so any value survives intact.
env_line() {
    local v="$2"
    # systemd treats \ " $ ` as escapable inside double quotes; escape all four
    # so a value (e.g. a password) can never be expanded or cut short.
    v="${v//\\/\\\\}"; v="${v//\"/\\\"}"; v="${v//\$/\\\$}"; v="${v//\`/\\\`}"
    printf '%s="%s"\n' "$1" "$v"
}

# ── Boot config (/boot/firmware/config.txt) ──────────────────────────────────
BLOCK_BEGIN="# >>> tuneout-display (managed by install.sh — do not edit) >>>"
BLOCK_END="# <<< tuneout-display <<<"

# set_boot_block "lines" — replaces our managed block (or removes it when
# empty). Flags a reboot when anything changes.
set_boot_block() {
    local body="$1" tmp
    [ -f "$BOOT_CONFIG" ] || { warn "$BOOT_CONFIG not found — skipping boot config."; return; }
    tmp="$(mktemp)"
    # Strip any existing block.
    awk -v b="$BLOCK_BEGIN" -v e="$BLOCK_END" '
        $0==b {skip=1; next}
        $0==e {skip=0; next}
        !skip {print}' "$BOOT_CONFIG" > "$tmp"
    if [ -n "$body" ]; then
        printf '%s\n[all]\n%s\n%s\n' "$BLOCK_BEGIN" "$body" "$BLOCK_END" >> "$tmp"
    fi
    if ! cmp -s "$tmp" "$BOOT_CONFIG"; then
        # cp, not install: /boot/firmware is FAT, which rejects chown/chmod.
        sudo cp "$tmp" "$BOOT_CONFIG"
        REBOOT_REQUIRED=1
        info "Updated $BOOT_CONFIG (reboot required)."
    fi
    rm -f "$tmp"
}

# boot_sed 'sed-expr' — in-place edit of config.txt, flags reboot on change.
boot_sed() {
    [ -f "$BOOT_CONFIG" ] || return 0
    local before after
    before="$(md5sum < "$BOOT_CONFIG")"
    sudo sed -i "$1" "$BOOT_CONFIG"
    after="$(md5sum < "$BOOT_CONFIG")"
    if [ "$before" != "$after" ]; then REBOOT_REQUIRED=1; fi
}

# ── Packages ─────────────────────────────────────────────────────────────────
# apt_install pkg... — installs only what's missing, so re-runs are fast.
apt_install() {
    local p missing=()
    for p in "$@"; do
        dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "install ok installed" \
            || missing+=("$p")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        info "Installing: ${missing[*]}"
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}"
    fi
}

# ── systemd ──────────────────────────────────────────────────────────────────
unit_exists() { systemctl list-unit-files "$1.service" --no-legend 2>/dev/null | grep -q "^$1.service"; }

# enable_restart NAME — enable and (re)start a system service.
enable_restart() {
    sudo systemctl enable "$1" -q
    sudo systemctl restart "$1"
}

# disable_unit NAME [remove-unit-file-path] — stop + disable if present.
disable_unit() {
    if unit_exists "$1"; then
        sudo systemctl disable --now "$1" -q 2>/dev/null || true
        info "Disabled $1."
    fi
    if [ -n "${2:-}" ]; then remove_file "$2"; fi
}

# user_systemctl ARGS — talk to this user's systemd instance (PipeWire etc.).
user_systemctl() {
    XDG_RUNTIME_DIR="$RUNTIME_DIR" systemctl --user "$@"
}

# ── Misc ─────────────────────────────────────────────────────────────────────
# Same rule as v1, so an upgraded device keeps its HA device/entity IDs.
device_id_from_name() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | tr ' ' '_' | tr -cd 'a-z0-9_'
}

# url_origin URL — "https://host:port" part of a URL (for the wait-for-HA loop).
url_origin() {
    echo "$1" | sed -E 's#^([a-zA-Z]+://[^/]+).*#\1#'
}
