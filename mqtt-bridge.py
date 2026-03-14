#!/usr/bin/env python3
"""
Smart Display MQTT Bridge

Registers the Smart Display as a native Home Assistant device via MQTT
discovery. HA automatically creates volume and brightness slider entities
plus a Stop TTS button — no rest_command or input_number YAML required.

Entities created in HA:
  number  → Voice Volume    (controls Wyoming/TTS playback via seeed_tts softvol)
  number  → Media Volume    (controls Music Assistant playback via seeed_media softvol)
  number  → Brightness      (controls DSI backlight)
  button  → Stop TTS        (kills any in-progress aplay)

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
from pathlib import Path

import paho.mqtt.client as mqtt

# ── Configuration ──────────────────────────────────────────────────────────────
MQTT_HOST     = os.getenv("MQTT_HOST",     "homeassistant.local")
MQTT_PORT     = int(os.getenv("MQTT_PORT", "1883"))
MQTT_USERNAME = os.getenv("MQTT_USERNAME", "")
MQTT_PASSWORD = os.getenv("MQTT_PASSWORD", "")
DEVICE_NAME   = os.getenv("DEVICE_NAME",   "Smart Display")
DEVICE_ID     = os.getenv("DEVICE_ID",
                    os.uname().nodename.lower().replace("-", "_"))

# ── State file paths ───────────────────────────────────────────────────────────
HOME           = Path.home()
TTS_VOL_FILE   = HOME / ".smart-display-tts-volume"
MEDIA_VOL_FILE = HOME / ".smart-display-media-volume"
BACKLIGHT_DIR  = Path("/sys/class/backlight/10-0045")

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

def _button(entity_id: str, name: str, icon: str) -> dict:
    return {
        "name":                  name,
        "unique_id":             f"{DEVICE_ID}_{entity_id}",
        "device":                DEVICE,
        "command_topic":         command_topic(entity_id),
        "icon":                  icon,
        "availability_topic":    AVAIL_TOPIC,
        "payload_available":     "online",
        "payload_not_available": "offline",
        "payload_press":         "PRESS",
    }

# All discovery registrations: (config_topic, payload)
DISCOVERY = [
    (config_topic("number", "tts_volume"),
     _number("tts_volume",   "Voice Volume", "mdi:account-voice")),

    (config_topic("number", "media_volume"),
     _number("media_volume", "Media Volume", "mdi:music")),

    (config_topic("number", "brightness"),
     _number("brightness",   "Brightness",   "mdi:brightness-6", min_=0)),

    (config_topic("button", "stop_tts"),
     _button("stop_tts",     "Stop TTS",     "mdi:stop")),
]

COMMAND_TOPICS = {command_topic(e) for e in
                  ("tts_volume", "media_volume", "brightness", "stop_tts")}

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

def _set_brightness(level: int) -> None:
    try:
        max_b = int((BACKLIGHT_DIR / "max_brightness").read_text().strip())
        (BACKLIGHT_DIR / "brightness").write_text(str(int(level * max_b / 100)))
    except OSError as e:
        print(f"[backlight] Error: {e}")

def _stop_tts() -> None:
    subprocess.run(["pkill", "-f", "aplay"], capture_output=True)

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
    client.publish(state_topic("tts_volume"),   str(_read_state(TTS_VOL_FILE,   90)), retain=True)
    client.publish(state_topic("media_volume"), str(_read_state(MEDIA_VOL_FILE, 75)), retain=True)
    client.publish(state_topic("brightness"),   str(_read_brightness_pct()),           retain=True)

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

    elif topic == command_topic("stop_tts"):
        _stop_tts()
        print("[stop] TTS interrupted via MQTT.")


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
