#!/usr/bin/env python3
"""
TuneoutDisplay MQTT bridge (v2).

Registers the display as a Home Assistant device via MQTT discovery. Which
entities exist depends on the role the installer chose (FEATURES):

  brightness      number  Display backlight 0–100 % (min 0 so automations can
                          turn it fully off)
  screen          switch  Backlight power on/off (bl_power)
  dashboard       button  Reload Dashboard  ─┐ share …/dashboard/set
                  text    Dashboard URL     ─┘ (driven over Chrome DevTools)
  speaker_volume  number  Master output volume (PipeWire default sink)
  talk            button  Start listening (LVA peripheral API) — voice role

Entities for features that are off — and v1's retired entities (tts_volume,
media_volume, mic_gain) — are removed from HA by publishing an empty config.

Per-stream volume is not handled here on purpose: LVA exposes its own media
player (with volume) to HA over ESPHome, and Music Assistant controls the
sendspin player's volume. This bridge only owns the master level.

Configuration (systemd EnvironmentFile /etc/smart-display/mqtt.env):
  MQTT_HOST, MQTT_PORT, MQTT_USERNAME, MQTT_PASSWORD
  DEVICE_NAME, DEVICE_ID
  DASHBOARD_URL, CDP_PORT
  FEATURES                 comma list of the features above
  DEFAULT_SPEAKER_VOLUME   used until a level has been set from HA
  PERIPHERAL_PORT          LVA peripheral WebSocket port (default 6055)
  BACKLIGHT_DEVICE         optional; auto-detected from /sys/class/backlight
"""

import json
import os
import re
import signal
import subprocess
import sys
import threading
import time
import urllib.request
from pathlib import Path

import paho.mqtt.client as mqtt

# websocket-client (Debian: python3-websocket) — used for Chromium (CDP) and
# the LVA peripheral API. Optional so the bridge still runs without it.
try:
    import websocket  # type: ignore
except Exception:  # pragma: no cover
    websocket = None

SW_VERSION = "2.0"

# ── Configuration ──────────────────────────────────────────────────────────────
MQTT_HOST     = os.getenv("MQTT_HOST",     "homeassistant.local")
MQTT_PORT     = int(os.getenv("MQTT_PORT", "1883"))
MQTT_USERNAME = os.getenv("MQTT_USERNAME", "")
MQTT_PASSWORD = os.getenv("MQTT_PASSWORD", "")
DEVICE_NAME   = os.getenv("DEVICE_NAME",   "Smart Display")
DEVICE_ID     = os.getenv("DEVICE_ID") or re.sub(r"[^a-z0-9_]", "_", os.uname().nodename.lower())
CDP_PORT      = int(os.getenv("CDP_PORT", "9222"))
DASHBOARD_URL = os.getenv("DASHBOARD_URL", "")
PERIPHERAL_PORT = int(os.getenv("PERIPHERAL_PORT", "6055"))
FEATURES      = {f.strip() for f in os.getenv("FEATURES", "brightness,screen,dashboard").split(",") if f.strip()}
DEFAULT_SPEAKER_VOLUME = int(os.getenv("DEFAULT_SPEAKER_VOLUME", "80"))

SPEAKER_VOL_FILE = Path.home() / ".smart-display-speaker-volume"


def _find_backlight() -> Path | None:
    name = os.getenv("BACKLIGHT_DEVICE")  # a device name, or an absolute path
    if name:
        return Path(name) if name.startswith("/") else Path("/sys/class/backlight") / name
    devices = sorted(Path("/sys/class/backlight").glob("*"))
    return devices[0] if devices else None


BACKLIGHT_DIR = _find_backlight()
if BACKLIGHT_DIR is None:
    print("[backlight] No /sys/class/backlight device — brightness/screen disabled.")
    FEATURES -= {"brightness", "screen"}

# ── MQTT topics ────────────────────────────────────────────────────────────────
BASE = f"smart-display/{DEVICE_ID}"
AVAIL_TOPIC = f"{BASE}/availability"


def state_topic(entity: str) -> str:
    return f"{BASE}/{entity}/state"


def command_topic(entity: str) -> str:
    return f"{BASE}/{entity}/set"


def config_topic(component: str, entity: str) -> str:
    return f"homeassistant/{component}/{DEVICE_ID}/{entity}/config"


DEVICE = {
    "identifiers":  [DEVICE_ID],
    "name":         DEVICE_NAME,
    "model":        "TuneoutDisplay",
    "manufacturer": "DIY",
    "sw_version":   SW_VERSION,
}

COMMON = {
    "device":                DEVICE,
    "availability_topic":    AVAIL_TOPIC,
    "payload_available":     "online",
    "payload_not_available": "offline",
}


def _number(entity: str, name: str, icon: str) -> dict:
    return {
        **COMMON,
        "name":                name,
        "unique_id":           f"{DEVICE_ID}_{entity}",
        "state_topic":         state_topic(entity),
        "command_topic":       command_topic(entity),
        "min":                 0,
        "max":                 100,
        "step":                5,
        "unit_of_measurement": "%",
        "icon":                icon,
        "retain":              True,
    }


# (feature, component, entity_id, payload). Each entity belongs to a feature.
ENTITIES = [
    ("brightness", "number", "brightness",
     _number("brightness", "Brightness", "mdi:brightness-6")),

    ("screen", "switch", "screen", {
        **COMMON,
        "name":          "Screen",
        "unique_id":     f"{DEVICE_ID}_screen",
        "state_topic":   state_topic("screen"),
        "command_topic": command_topic("screen"),
        "payload_on":    "ON",
        "payload_off":   "OFF",
        "icon":          "mdi:monitor",
        "retain":        True,
    }),

    ("dashboard", "button", "dashboard_reload", {
        **COMMON,
        "name":          "Reload Dashboard",
        "unique_id":     f"{DEVICE_ID}_dashboard_reload",
        "command_topic": command_topic("dashboard"),
        "payload_press": "reload",
        "icon":          "mdi:refresh",
    }),

    ("dashboard", "text", "dashboard_url", {
        **COMMON,
        "name":          "Dashboard URL",
        "unique_id":     f"{DEVICE_ID}_dashboard_url",
        "command_topic": command_topic("dashboard"),
        "state_topic":   state_topic("dashboard_url"),
        "mode":          "text",
        "min":           0,
        "max":           255,
        "icon":          "mdi:link-variant",
    }),

    ("speaker_volume", "number", "speaker_volume",
     _number("speaker_volume", "Speaker Volume", "mdi:volume-high")),

    ("talk", "button", "talk", {
        **COMMON,
        "name":          "Start Listening",
        "unique_id":     f"{DEVICE_ID}_talk",
        "command_topic": command_topic("talk"),
        "payload_press": "PRESS",
        "icon":          "mdi:microphone-message",
    }),
]

# v1 entities that no longer exist — cleared from HA on connect.
RETIRED = [("number", "tts_volume"), ("number", "media_volume"), ("number", "mic_gain")]

# ── Backlight ──────────────────────────────────────────────────────────────────
def _bl_read(attr: str) -> int:
    return int((BACKLIGHT_DIR / attr).read_text().strip())


def _bl_write(attr: str, value: int) -> None:
    try:
        (BACKLIGHT_DIR / attr).write_text(str(value))
    except OSError as e:
        print(f"[backlight] Write {attr} failed: {e}")


def read_brightness_pct() -> int:
    try:
        return max(0, min(100, round(_bl_read("brightness") * 100 / _bl_read("max_brightness"))))
    except (OSError, ValueError, ZeroDivisionError):
        return 100


def set_brightness_pct(level: int) -> None:
    try:
        _bl_write("brightness", round(level * _bl_read("max_brightness") / 100))
    except (OSError, ValueError) as e:
        print(f"[backlight] Error: {e}")


def read_screen_on() -> bool:
    try:
        return _bl_read("bl_power") == 0
    except (OSError, ValueError):
        return True


def set_screen_on(on: bool) -> None:
    _bl_write("bl_power", 0 if on else 4)  # FB_BLANK_UNBLANK / FB_BLANK_POWERDOWN

# ── Speaker volume (PipeWire default sink via wpctl) ───────────────────────────
def _wpctl(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["wpctl", *args], capture_output=True, text=True, timeout=5)


def read_speaker_volume() -> int | None:
    try:
        r = _wpctl("get-volume", "@DEFAULT_AUDIO_SINK@")
    except (OSError, subprocess.TimeoutExpired):
        return None
    m = re.search(r"Volume:\s*([0-9.]+)", r.stdout)
    return round(float(m.group(1)) * 100) if (r.returncode == 0 and m) else None


def set_speaker_volume(level: int) -> bool:
    try:
        r = _wpctl("set-volume", "@DEFAULT_AUDIO_SINK@", f"{level / 100:.2f}")
    except (OSError, subprocess.TimeoutExpired) as e:
        print(f"[speaker] wpctl failed: {e}")
        return False
    if r.returncode != 0:
        print(f"[speaker] wpctl: {r.stderr.strip() or r.stdout.strip()}")
    return r.returncode == 0


def saved_speaker_volume() -> int:
    try:
        return max(0, min(100, int(SPEAKER_VOL_FILE.read_text().strip())))
    except (OSError, ValueError):
        return DEFAULT_SPEAKER_VOLUME


def restore_speaker_volume() -> None:
    """At boot PipeWire may come up after us; retry until the sink exists."""
    level = saved_speaker_volume()
    for _ in range(60):
        if read_speaker_volume() is not None and set_speaker_volume(level):
            print(f"[speaker] Restored {level}%.")
            client.publish(state_topic("speaker_volume"), str(level), retain=True)
            return
        time.sleep(2)
    print("[speaker] No PipeWire sink after 2 min — volume not restored.")

# ── Chromium (Chrome DevTools Protocol) ────────────────────────────────────────
def _cdp_send(method: str, params: dict | None = None) -> bool:
    if websocket is None:
        print("[cdp] python3-websocket not installed.")
        return False
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{CDP_PORT}/json", timeout=3) as r:
            targets = json.loads(r.read().decode())
        ws_url = next((t["webSocketDebuggerUrl"] for t in targets
                       if t.get("type") == "page" and t.get("webSocketDebuggerUrl")), None)
    except Exception as e:
        print(f"[cdp] Debug endpoint unreachable on :{CDP_PORT} ({e}).")
        return False
    if not ws_url:
        print("[cdp] No page target.")
        return False
    try:
        # No Origin header: Chromium accepts that without --remote-allow-origins.
        ws = websocket.create_connection(ws_url, timeout=5, suppress_origin=True)
        ws.send(json.dumps({"id": 1, "method": method, "params": params or {}}))
        ws.recv()
        ws.close()
        return True
    except Exception as e:
        print(f"[cdp] {method} failed: {e}")
        return False


def handle_dashboard(payload: str) -> None:
    """''/reload/refresh → reload; home → DASHBOARD_URL; http(s)://… → navigate."""
    cmd = payload.strip()
    low = cmd.lower()
    if low in ("", "reload", "refresh"):
        ok = _cdp_send("Page.reload", {"ignoreCache": True})
        print(f"[dashboard] reload → {'ok' if ok else 'failed'}")
        return
    if low == "home":
        url = DASHBOARD_URL
    elif low.startswith(("http://", "https://")):
        url = cmd
    else:
        print(f"[dashboard] Ignored payload: {cmd!r}")
        return
    if not url:
        print("[dashboard] 'home' requested but DASHBOARD_URL is empty.")
        return
    ok = _cdp_send("Page.navigate", {"url": url})
    if ok:
        client.publish(state_topic("dashboard_url"), url, retain=True)
    print(f"[dashboard] navigate → {url} ({'ok' if ok else 'failed'})")

# ── LVA peripheral API (push-to-talk) ──────────────────────────────────────────
def lva_command(command: str) -> None:
    if websocket is None:
        print("[lva] python3-websocket not installed.")
        return
    try:
        ws = websocket.create_connection(f"ws://127.0.0.1:{PERIPHERAL_PORT}", timeout=5,
                                         suppress_origin=True)
        ws.send(json.dumps({"command": command}))
        ws.close()
        print(f"[lva] {command} sent.")
    except Exception as e:
        print(f"[lva] {command} failed: {e}")

# ── MQTT ───────────────────────────────────────────────────────────────────────
def _pct(payload: str) -> int | None:
    try:
        return max(0, min(100, int(float(payload))))
    except ValueError:
        return None


def on_connect(client, userdata, flags, reason_code, properties):
    if reason_code.is_failure:
        print(f"[mqtt] Connection failed: {reason_code} — retrying.")
        return
    print(f"[mqtt] Connected to {MQTT_HOST}:{MQTT_PORT} as '{DEVICE_ID}'.")
    client.publish(AVAIL_TOPIC, "online", retain=True)

    # Register enabled entities; clear disabled and retired ones.
    for feature, component, entity, payload in ENTITIES:
        topic = config_topic(component, entity)
        client.publish(topic, json.dumps(payload) if feature in FEATURES else "", retain=True)
    for component, entity in RETIRED:
        client.publish(config_topic(component, entity), "", retain=True)

    if "brightness" in FEATURES:
        client.publish(state_topic("brightness"), str(read_brightness_pct()), retain=True)
    if "screen" in FEATURES:
        client.publish(state_topic("screen"), "ON" if read_screen_on() else "OFF", retain=True)
    if "dashboard" in FEATURES:
        client.publish(state_topic("dashboard_url"), DASHBOARD_URL, retain=True)
    if "speaker_volume" in FEATURES:
        vol = read_speaker_volume()
        client.publish(state_topic("speaker_volume"),
                       str(vol if vol is not None else saved_speaker_volume()), retain=True)

    for entity in ("brightness", "screen", "dashboard", "speaker_volume", "talk"):
        client.subscribe(command_topic(entity))
    print(f"[mqtt] Discovery published ({', '.join(sorted(FEATURES))}).")


def on_message(client, userdata, msg):
    topic = msg.topic
    payload = msg.payload.decode(errors="replace").strip()

    if topic == command_topic("brightness") and "brightness" in FEATURES:
        level = _pct(payload)
        if level is None:
            return
        set_brightness_pct(level)
        client.publish(state_topic("brightness"), str(level), retain=True)
        print(f"[brightness] → {level}%")

    elif topic == command_topic("screen") and "screen" in FEATURES:
        on = payload.upper() == "ON"
        set_screen_on(on)
        client.publish(state_topic("screen"), "ON" if on else "OFF", retain=True)
        print(f"[screen] → {'on' if on else 'off'}")

    elif topic == command_topic("dashboard") and "dashboard" in FEATURES:
        # CDP calls block for up to a few seconds — keep the MQTT loop free.
        threading.Thread(target=handle_dashboard, args=(payload,), daemon=True).start()

    elif topic == command_topic("speaker_volume") and "speaker_volume" in FEATURES:
        level = _pct(payload)
        if level is None:
            return
        if set_speaker_volume(level):
            try:
                SPEAKER_VOL_FILE.write_text(str(level))
            except OSError as e:
                print(f"[speaker] Save failed: {e}")
            client.publish(state_topic("speaker_volume"), str(level), retain=True)
            print(f"[speaker] → {level}%")

    elif topic == command_topic("talk") and "talk" in FEATURES:
        threading.Thread(target=lva_command, args=("start_listening",), daemon=True).start()


def on_disconnect(client, userdata, flags, reason_code, properties):
    if reason_code.is_failure:
        print(f"[mqtt] Unexpected disconnect: {reason_code}. Reconnecting.")


def _shutdown(sig, frame):
    print("[exit] Shutting down.")
    client.publish(AVAIL_TOPIC, "offline", retain=True)
    client.disconnect()
    sys.exit(0)


client = mqtt.Client(
    callback_api_version=mqtt.CallbackAPIVersion.VERSION2,
    client_id=f"smart-display-{DEVICE_ID}",
)
client.on_connect = on_connect
client.on_message = on_message
client.on_disconnect = on_disconnect
client.will_set(AVAIL_TOPIC, "offline", retain=True)
client.reconnect_delay_set(min_delay=1, max_delay=32)
if MQTT_USERNAME:
    client.username_pw_set(MQTT_USERNAME, MQTT_PASSWORD)

if __name__ == "__main__":
    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)

    print(f"[ready] TuneoutDisplay MQTT bridge {SW_VERSION}")
    print(f"        Broker   : {MQTT_HOST}:{MQTT_PORT}")
    print(f"        Device   : {DEVICE_NAME} ({DEVICE_ID})")
    print(f"        Features : {', '.join(sorted(FEATURES))}")
    if BACKLIGHT_DIR:
        print(f"        Backlight: {BACKLIGHT_DIR}")

    if "speaker_volume" in FEATURES:
        threading.Thread(target=restore_speaker_volume, daemon=True).start()

    client.connect_async(MQTT_HOST, MQTT_PORT, keepalive=60)
    client.loop_forever()
