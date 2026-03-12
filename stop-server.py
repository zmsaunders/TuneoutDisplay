#!/usr/bin/env python3
"""
Smart Display control server.

Endpoints:
  GET /stop                  — kill any running aplay (stops TTS mid-sentence)
  GET /tts-volume?level=N    — set voice/TTS playback volume to N% (0-100)
  GET /media-volume?level=N  — set music/media playback volume to N% (0-100)
  GET /brightness?level=N    — set DSI display brightness to N% (0-100)

TTS and media volumes are independent ALSA softvol controls so they can be
adjusted separately from Home Assistant without affecting each other.
The WM8960 hardware speaker level is fixed; only the per-stream software
volumes are exposed here.
"""
import os, signal, subprocess, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

PORT = 12345

TTS_VOLUME_STATE_FILE   = os.path.expanduser("~/.smart-display-tts-volume")
MEDIA_VOLUME_STATE_FILE = os.path.expanduser("~/.smart-display-media-volume")

BACKLIGHT_DIR  = "/sys/class/backlight/10-0045"
BACKLIGHT_PATH = f"{BACKLIGHT_DIR}/brightness"
try:
    with open(f"{BACKLIGHT_DIR}/max_brightness") as _f:
        BACKLIGHT_MAX = int(_f.read().strip())
except OSError:
    BACKLIGHT_MAX = 255


def _set_alsa_volume(control: str, level: int) -> tuple[bool, str]:
    """Set an ALSA softvol control on the seeed card. Returns (ok, error_msg).

    softvol controls are raw mixer elements — they are not visible to sset
    (simple mixer). cset with name= reaches them directly.
    """
    result = subprocess.run(
        ["/usr/bin/amixer", "-c", "seeed2micvoicec", "cset", f"name={control}", f"{level}%"],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        return False, result.stderr.strip()
    return True, ""


def _save_state(path: str, value: int) -> None:
    try:
        with open(path, "w") as f:
            f.write(str(value))
    except OSError:
        pass


def _parse_level(params: dict) -> int | None:
    """Parse ?level=N from query params. Returns int 0-100 or None on error."""
    try:
        return max(0, min(100, int(float(params.get("level", [""])[0]))))
    except (ValueError, IndexError):
        return None


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urlparse(self.path)
        path   = parsed.path
        params = parse_qs(parsed.query)

        if path == "/stop":
            self._handle_stop()

        elif path == "/tts-volume":
            level = _parse_level(params)
            if level is None:
                self._respond(400, "bad request — use /tts-volume?level=0-100")
                return
            ok, err = _set_alsa_volume("TTS Volume", level)
            if not ok:
                print(f"[tts-volume] amixer error: {err}")
            _save_state(TTS_VOLUME_STATE_FILE, level)
            print(f"[tts-volume] Set to {level}%.")
            self._respond(200, str(level))

        elif path == "/media-volume":
            level = _parse_level(params)
            if level is None:
                self._respond(400, "bad request — use /media-volume?level=0-100")
                return
            ok, err = _set_alsa_volume("Media Volume", level)
            if not ok:
                print(f"[media-volume] amixer error: {err}")
            _save_state(MEDIA_VOLUME_STATE_FILE, level)
            print(f"[media-volume] Set to {level}%.")
            self._respond(200, str(level))

        elif path == "/brightness":
            level = _parse_level(params)
            if level is None:
                self._respond(400, "bad request — use /brightness?level=0-100")
                return
            raw = int(level * BACKLIGHT_MAX / 100)
            try:
                with open(BACKLIGHT_PATH, "w") as f:
                    f.write(str(raw))
                print(f"[brightness] Set to {level}% ({raw}/{BACKLIGHT_MAX}).")
                self._respond(200, str(level))
            except OSError as e:
                print(f"[brightness] Error writing backlight: {e}")
                self._respond(500, f"error: {e}")

        else:
            self._respond(404, "not found")

    def _handle_stop(self):
        result = subprocess.run(["pkill", "-f", "aplay"], capture_output=True)
        if result.returncode == 0:
            print("[stop] aplay killed — TTS interrupted.")
            self._respond(200, "stopped")
        else:
            print("[stop] nothing playing.")
            self._respond(200, "idle")

    def _respond(self, code: int, body: str) -> None:
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(body.encode())

    def log_message(self, fmt, *args):
        print(f"[http] {self.address_string()} {fmt % args}")


def _exit(sig, frame):
    print("[exit] Stop server shutting down.")
    sys.exit(0)


signal.signal(signal.SIGTERM, _exit)
signal.signal(signal.SIGINT, _exit)

server = HTTPServer(("0.0.0.0", PORT), Handler)
print(f"[ready] Smart Display control server listening on port {PORT}.")
server.serve_forever()
