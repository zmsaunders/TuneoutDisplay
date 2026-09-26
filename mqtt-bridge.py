#!/usr/bin/env python3
"""
Smart Display MQTT Bridge

Registers the Smart Display as a native Home Assistant device via MQTT
discovery. HA automatically creates volume and brightness slider entities
plus a Stop TTS button — no rest_command or input_number YAML required.

Entities created in HA:
  number  → Voice Volume     (controls Wyoming/TTS playback via seeed_tts softvol)
  number  → Media Volume     (controls Music Assistant playback via seeed_media softvol)
  number  → Brightness       (controls DSI backlight)
  number  → Mic Sensitivity  (WM8960 Capture PGA gain)
  button  → Reload Dashboard (reloads the kiosk page over CDP)
  text    → Dashboard URL    (navigates the kiosk to any URL over CDP)

Configuration (set via systemd environment / EnvironmentFile):
  MQTT_HOST      Broker hostname or IP   (default: homeassistant.local)
  MQTT_PORT      Broker port             (default: 1883)
  MQTT_USERNAME  Broker username         (default: empty)
  MQTT_PASSWORD  Broker password         (default: empty)
  DEVICE_NAME    Human-readable name     (default: Smart Display)
  DEVICE_ID      Unique slug for topics  (default: derived from hostname)
"""

import json
import os
import signal
import subprocess
import sys
import urllib.request
from pathlib import Path

import paho.mqtt.client as mqtt

# websocket-client (Debian: python3-websocket) — used to drive Chromium over the
# Chrome DevTools Protocol for the dashboard reload / navigate commands. Optional
# so the bridge still runs (minus that feature) if the package is missing.
try:
    import websocket  # type: ignore
except Exception:  # pragma: no cover
    websocket = None

# ── Configuration ──────────────────────────────────────────────────────────────
MQTT_HOST     = os.getenv("MQTT_HOST",     "homeassistant.local")
MQTT_PORT     = int(os.getenv("MQTT_PORT", "1883"))
MQTT_USERNAME = os.getenv("MQTT_USERNAME", "")
MQTT_PASSWORD = os.getenv("MQTT_PASSWORD", "")
DEVICE_NAME   = os.getenv("DEVICE_NAME",   "Smart Display")
DEVICE_ID     = os.getenv("DEVICE_ID",
                    os.uname().nodename.lower().replace("-", "_"))

# Dashboard refresh: the kiosk Chromium is launched with --remote-debugging-port
# so the bridge can reload it or navigate it to a new URL over CDP — e.g. to
# recover the display after Home Assistant reboots, or to push a test dashboard.
CDP_PORT      = int(os.getenv("CDP_PORT", "9222"))
DASHBOARD_URL = os.getenv("DASHBOARD_URL", "")  # the device's configured kiosk URL

# ── State file paths ───────────────────────────────────────────────────────────
HOME           = Path.home()
TTS_VOL_FILE   = HOME / ".smart-display-tts-volume"
MEDIA_VOL_FILE = HOME / ".smart-display-media-volume"
MIC_GAIN_FILE  = HOME / ".smart-display-mic-gain"
BACKLIGHT_DIR  = Path("/sys/class/backlight/10-0045")

# WM8960 Capture PGA gain range (numid=1): ALSA values 0–63.
# 0 = minimum gain (~-17 dB),  63 = maximum gain (+30 dB),  40 = 0 dB default.
MIC_GAIN_ALSA_MAX = 63

# ── MQTT topic helpers ─────────────────────────────────────────────────────────
BASE = f"smart-display/{DEVICE_ID}"
AVAIL_TOPIC = f"{BASE}/availability"

def state_topic(entity:   str) -> str: return f"{BASE}/{entity}/state"
def command_topic(entity: str) -> str: return f"{BASE}/{entity}/set"
def config_topic(component: str, entity: str) -> str:
    return f"homeassistant/{component}/{DEVICE_ID}/{entity}/config"

# ── Shared device descriptor ───────────────────────────────────────────────────
DEVICE = {
    "identifiers":  [DEVICE_ID],
    "name":         DEVICE_NAME,
    "model":        "Smart Display",
    "manufacturer": "DIY",
    "sw_version":   "1.0",
}

# ── Discovery payload builders ─────────────────────────────────────────────────
def _number(entity_id: str, name: str, icon: str,
            min_: int = 0, max_: int = 100, step: int = 5) -> dict:
    return {
        "name":                  name,
        "unique_id":             f"{DEVICE_ID}_{entity_id}",
        "device":                DEVICE,
        "state_topic":           state_topic(entity_id),
        "command_topic":         command_topic(entity_id),
        "min":                   min_,
        "max":                   max_,
        "step":                  step,
        "unit_of_measurement":   "%",
        "icon":                  icon,
        "availability_topic":    AVAIL_TOPIC,
        "payload_available":     "online",
        "payload_not_available": "offline",
        "retain":                True,
        "optimistic":            False,
    }

# All discovery registrations: (config_topic, payload)
DISCOVERY = [
    (config_topic("number", "tts_volume"),
     _number("tts_volume",   "Voice Volume", "mdi:account-voice")),

    (config_topic("number", "media_volume"),
     _number("media_volume", "Media Volume", "mdi:music")),

    (config_topic("number", "brightness"),
     _number("brightness",   "Brightness",   "mdi:brightness-6", min_=0)),

    (config_topic("number", "mic_gain"),
     _number("mic_gain",     "Mic Sensitivity", "mdi:microphone-settings")),

    # Dashboard refresh — a button that reloads the kiosk page, and a text box
    # to navigate it to any URL. Both publish to the shared "dashboard" command
    # topic; the bridge drives Chromium over CDP. Handy after an HA reboot or to
    # push a test dashboard to the screen.
    (config_topic("button", "dashboard_reload"), {
        "name":                  "Reload Dashboard",
        "unique_id":             f"{DEVICE_ID}_dashboard_reload",
        "device":                DEVICE,
        "command_topic":         command_topic("dashboard"),
        "payload_press":         "reload",
        "icon":                  "mdi:refresh",
        "availability_topic":    AVAIL_TOPIC,
        "payload_available":     "online",
        "payload_not_available": "offline",
    }),

    (config_topic("text", "dashboard_url"), {
        "name":                  "Dashboard URL",
        "unique_id":             f"{DEVICE_ID}_dashboard_url",
        "device":                DEVICE,
        "command_topic":         command_topic("dashboard"),
        "state_topic":           state_topic("dashboard_url"),
        "mode":                  "text",
        "min":                   0,
        "max":                   255,
        "icon":                  "mdi:link-variant",
        "availability_topic":    AVAIL_TOPIC,
        "payload_available":     "online",
        "payload_not_available": "offline",
    }),

]

COMMAND_TOPICS = {command_topic(e) for e in
                  ("tts_volume", "media_volume", "brightness", "mic_gain",
                   "dashboard")}

# ── Hardware helpers ───────────────────────────────────────────────────────────
def _read_state(path: Path, default: int) -> int:
    try:
        return max(0, min(100, int(path.read_text().strip())))
    except (OSError, ValueError):
        return default

def _write_state(path: Path, value: int) -> None:
    try:
        path.write_text(str(value))
    except OSError as e:
        print(f"[state] Write failed {path}: {e}")

def _read_brightness_pct() -> int:
    try:
        max_b    = int((BACKLIGHT_DIR / "max_brightness").read_text().strip())
        current  = int((BACKLIGHT_DIR / "brightness").read_text().strip())
        return max(0, min(100, round(current * 100 / max_b)))
    except OSError:
        return 100

def _set_alsa(control: str, level: int) -> None:
    # softvol controls are raw mixer elements — not visible to sset (simple
    # mixer). cset with name= reaches them directly.
    r = subprocess.run(
        ["/usr/bin/amixer", "-c", "seeed2micvoicec", "cset", f"name={control}", f"{level}%"],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        print(f"[alsa] Error setting '{control}': {r.stderr.strip()}")

def _read_mic_gain_pct() -> int:
    """Read current WM8960 Capture PGA gain and return as 0–100%."""
    r = subprocess.run(
        ["/usr/bin/amixer", "-c", "seeed2micvoicec", "cget", "numid=1"],
        capture_output=True, text=True,
    )
    if r.returncode == 0:
        for line in r.stdout.splitlines():
            if "values=" in line:
                try:
                    raw = int(line.split("values=")[1].split(",")[0].strip())
                    return max(0, min(100, round(raw * 100 / MIC_GAIN_ALSA_MAX)))
                except (ValueError, IndexError):
                    pass
    return _read_state(MIC_GAIN_FILE, 63)

def _set_mic_gain(level_pct: int) -> None:
    """Set WM8960 Capture PGA gain from 0–100% (maps to ALSA 0–63)."""
    alsa_val = round(level_pct * MIC_GAIN_ALSA_MAX / 100)
    r = subprocess.run(
        ["/usr/bin/amixer", "-c", "seeed2micvoicec", "cset", "numid=1",
         f"{alsa_val},{alsa_val}"],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        print(f"[alsa] Error setting mic gain: {r.stderr.strip()}")

def _set_brightness(level: int) -> None:
    try:
        max_b = int((BACKLIGHT_DIR / "max_brightness").read_text().strip())
        (BACKLIGHT_DIR / "brightness").write_text(str(int(level * max_b / 100)))
    except OSError as e:
        print(f"[backlight] Error: {e}")

# ── Chromium control (Chrome DevTools Protocol) ────────────────────────────────
# Chromium is launched in the kiosk with --remote-debugging-port=CDP_PORT, so we
# can reload it or navigate it without touching the Wayland session. This is the
# recovery path when HA reboots and the displays are left on a dead page.

def _cdp_ws_url() -> str | None:
    """Return the WebSocket debugger URL for the active kiosk page, or None."""
    with urllib.request.urlopen(
            f"http://127.0.0.1:{CDP_PORT}/json", timeout=3) as r:
        targets = json.loads(r.read().decode())
    for t in targets:
        if t.get("type") == "page" and t.get("webSocketDebuggerUrl"):
            return t["webSocketDebuggerUrl"]
    return None

def _cdp_send(method: str, params: dict | None = None) -> bool:
    """Send a single CDP command to the kiosk page. Returns True on success."""
    if websocket is None:
        print("[cdp] python3-websocket not installed — cannot drive Chromium.")
        return False
    try:
        ws_url = _cdp_ws_url()
    except Exception as e:
        print(f"[cdp] Chromium debug endpoint unreachable on :{CDP_PORT} ({e}).")
        return False
    if not ws_url:
        print("[cdp] No page target on Chromium debug endpoint.")
        return False
    try:
        ws = websocket.create_connection(
            ws_url, timeout=5, origin=f"http://127.0.0.1:{CDP_PORT}")
        ws.send(json.dumps({"id": 1, "method": method, "params": params or {}}))
        ws.recv()
        ws.close()
        return True
    except Exception as e:
        print(f"[cdp] {method} failed: {e}")
        return False

def _handle_dashboard(client, payload: str) -> None:
    """Interpret a dashboard command payload and drive Chromium accordingly.

      ''/'reload'/'refresh' → reload the current page (ignoring cache)
      'home'                → navigate back to the configured kiosk URL
      'http(s)://…'         → navigate to that URL (e.g. a test dashboard)
    """
    cmd = payload.strip()
    low = cmd.lower()
    if low in ("", "reload", "refresh"):
        ok = _cdp_send("Page.reload", {"ignoreCache": True})
        print(f"[dashboard] reload → {'ok' if ok else 'failed'}")
    elif low == "home":
        if not DASHBOARD_URL:
            print("[dashboard] 'home' requested but DASHBOARD_URL is empty.")
            return
        ok = _cdp_send("Page.navigate", {"url": DASHBOARD_URL})
        if ok:
            client.publish(state_topic("dashboard_url"), DASHBOARD_URL, retain=True)
        print(f"[dashboard] home → {DASHBOARD_URL} ({'ok' if ok else 'failed'})")
    elif low.startswith("http://") or low.startswith("https://"):
        ok = _cdp_send("Page.navigate", {"url": cmd})
        if ok:
            client.publish(state_topic("dashboard_url"), cmd, retain=True)
        print(f"[dashboard] navigate → {cmd} ({'ok' if ok else 'failed'})")
    else:
        print(f"[dashboard] ignored unrecognised payload: {cmd!r}")

# ── MQTT callbacks ─────────────────────────────────────────────────────────────
def on_connect(client, userdata, connect_flags, reason_code, properties):
    if reason_code.is_failure:
        print(f"[mqtt] Connection failed: {reason_code} — will retry.")
        return

    print(f"[mqtt] Connected to {MQTT_HOST}:{MQTT_PORT} as '{DEVICE_ID}'.")

    # Mark device online
    client.publish(AVAIL_TOPIC, "online", retain=True)

    # Register all entities via MQTT discovery
    for topic, payload in DISCOVERY:
        client.publish(topic, json.dumps(payload), retain=True)

    # Publish current state so HA sliders reflect actual values immediately
    client.publish(state_topic("tts_volume"),   str(_read_state(TTS_VOL_FILE, 100)), retain=True)
    client.publish(state_topic("media_volume"), str(_read_state(MEDIA_VOL_FILE, 90)), retain=True)
    client.publish(state_topic("brightness"),   str(_read_brightness_pct()),           retain=True)
    client.publish(state_topic("mic_gain"),     str(_read_mic_gain_pct()),             retain=True)
    client.publish(state_topic("dashboard_url"), DASHBOARD_URL,                         retain=True)

    # Subscribe to all command topics
    for topic in COMMAND_TOPICS:
        client.subscribe(topic)

    print("[mqtt] Discovery published. Listening for commands.")


def on_message(client, userdata, msg):
    topic   = msg.topic
    payload = msg.payload.decode().strip()

    if topic == command_topic("tts_volume"):
        try:
            level = max(0, min(100, int(float(payload))))
        except ValueError:
            return
        _set_alsa("TTS Volume", level)
        _write_state(TTS_VOL_FILE, level)
        client.publish(state_topic("tts_volume"), str(level), retain=True)
        print(f"[tts-volume] → {level}%")

    elif topic == command_topic("media_volume"):
        try:
            level = max(0, min(100, int(float(payload))))
        except ValueError:
            return
        _set_alsa("Media Volume", level)
        _write_state(MEDIA_VOL_FILE, level)
        client.publish(state_topic("media_volume"), str(level), retain=True)
        print(f"[media-volume] → {level}%")

    elif topic == command_topic("brightness"):
        try:
            level = max(0, min(100, int(float(payload))))
        except ValueError:
            return
        _set_brightness(level)
        client.publish(state_topic("brightness"), str(level), retain=True)
        print(f"[brightness] → {level}%")

    elif topic == command_topic("mic_gain"):
        try:
            level = max(0, min(100, int(float(payload))))
        except ValueError:
            return
        _set_mic_gain(level)
        _write_state(MIC_GAIN_FILE, level)
        client.publish(state_topic("mic_gain"), str(level), retain=True)
        print(f"[mic-gain] → {level}% (ALSA {round(level * MIC_GAIN_ALSA_MAX / 100)})")

    elif topic == command_topic("dashboard"):
        _handle_dashboard(client, payload)

def on_disconnect(client, userdata, disconnect_flags, reason_code, properties):
    if reason_code.is_failure:
        print(f"[mqtt] Unexpected disconnect: {reason_code}. paho will reconnect.")


# ── Startup & signal handling ──────────────────────────────────────────────────
def _shutdown(sig, frame):
    print("[exit] MQTT bridge shutting down.")
    client.publish(AVAIL_TOPIC, "offline", retain=True)
    client.disconnect()
    sys.exit(0)

signal.signal(signal.SIGTERM, _shutdown)
signal.signal(signal.SIGINT,  _shutdown)

client = mqtt.Client(
    callback_api_version=mqtt.CallbackAPIVersion.VERSION2,
    client_id=f"smart-display-{DEVICE_ID}",
)
client.on_connect    = on_connect
client.on_message    = on_message
client.on_disconnect = on_disconnect

# LWT: if the Pi disconnects ungracefully, HA marks the device unavailable
client.will_set(AVAIL_TOPIC, "offline", retain=True)

# Automatic reconnection with exponential backoff (1s → 32s)
client.reconnect_delay_set(min_delay=1, max_delay=32)

if MQTT_USERNAME:
    client.username_pw_set(MQTT_USERNAME, MQTT_PASSWORD)

print(f"[ready] Smart Display MQTT bridge starting.")
print(f"        Broker  : {MQTT_HOST}:{MQTT_PORT}")
print(f"        Device  : {DEVICE_NAME} ({DEVICE_ID})")

client.connect_async(MQTT_HOST, MQTT_PORT, keepalive=60)
client.loop_forever()
