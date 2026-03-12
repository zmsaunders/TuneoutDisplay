#!/usr/bin/env python3
"""touch-scroll

Translates touchscreen vertical swipe gestures into scroll-wheel events via a
uinput virtual device.  The virtual device is discovered by libinput/wlroots
and forwarded to Wayland clients as wl_pointer.axis events, giving native
scroll behaviour in Chromium, Firefox, and any other Wayland application.

Does NOT grab the touch device, so tapping and control-dragging continue to
work normally via the compositor's existing touch-as-pointer emulation.
"""

import time
import evdev
from evdev import InputDevice, UInput, ecodes as e

# ── Tuning ─────────────────────────────────────────────────────────────────────

# How many scroll ticks to traverse the full screen height.
# Higher = faster scroll; lower = slower.
TICKS_PER_SCREEN = 40

# Substring to match against device names when locating the touchscreen.
DEVICE_NAME_HINT = 'ft5'

# Seconds to wait between retries while the device isn't yet available.
RETRY_DELAY = 1
MAX_RETRIES = 30

# ── Device discovery ───────────────────────────────────────────────────────────

def find_touch_device():
    """Return the first multitouch InputDevice, preferring the ft5x06."""
    for attempt in range(MAX_RETRIES):
        candidates = []
        for path in evdev.list_devices():
            try:
                dev  = InputDevice(path)
                caps = dev.capabilities()
                if e.EV_ABS not in caps:
                    continue
                abs_codes = [c for c, _ in caps[e.EV_ABS]]
                if e.ABS_MT_POSITION_Y not in abs_codes:
                    continue
                # Prefer the named device
                if DEVICE_NAME_HINT.lower() in dev.name.lower():
                    print(f"[touch-scroll] Found touch device: {dev.name} ({dev.path})",
                          flush=True)
                    return dev
                candidates.append(dev)
            except Exception:
                pass
        if candidates:
            dev = candidates[0]
            print(f"[touch-scroll] Found touch device: {dev.name} ({dev.path})",
                  flush=True)
            return dev
        print(f"[touch-scroll] No touch device yet, retrying ({attempt+1}/{MAX_RETRIES})…",
              flush=True)
        time.sleep(RETRY_DELAY)
    return None

# ── Main loop ──────────────────────────────────────────────────────────────────

def main():
    dev = find_touch_device()
    if dev is None:
        print("[touch-scroll] ERROR: No multitouch device found after retries.", flush=True)
        raise SystemExit(1)

    # Read Y-axis range so scroll speed is proportional to screen size
    abs_caps       = dict(dev.capabilities().get(e.EV_ABS, []))
    y_info         = abs_caps.get(e.ABS_MT_POSITION_Y)
    y_range        = (y_info.max - y_info.min) if y_info else 4095
    pixels_per_tick = max(y_range / TICKS_PER_SCREEN, 1)

    print(f"[touch-scroll] Y range: 0–{y_range}, {pixels_per_tick:.1f} units/tick", flush=True)

    # Virtual pointer device — must have EV_REL + BTN_* for libinput to
    # classify it as a pointer and forward its axis events to Wayland clients.
    ui = UInput(
        {
            e.EV_REL: [e.REL_X, e.REL_Y, e.REL_WHEEL],
            e.EV_KEY: [e.BTN_LEFT, e.BTN_RIGHT, e.BTN_MIDDLE],
        },
        name='touch-scroll-virtual',
        version=0x3,
    )

    tracking_id = None   # current active finger (None = no touch)
    last_y      = None   # last reported Y position
    accum       = 0.0    # sub-tick accumulator

    print("[touch-scroll] Running — swipe up/down to scroll.", flush=True)

    for event in dev.read_loop():
        if event.type != e.EV_ABS:
            continue

        # ── Finger down / up ──────────────────────────────────────────────────
        if event.code == e.ABS_MT_TRACKING_ID:
            if event.value == -1:          # finger lifted
                tracking_id = None
                last_y      = None
                accum       = 0.0
            else:                          # new finger contact
                tracking_id = event.value
                last_y      = None
                accum       = 0.0

        # ── Finger motion ─────────────────────────────────────────────────────
        elif event.code == e.ABS_MT_POSITION_Y and tracking_id is not None:
            if last_y is not None:
                # Positive delta = finger moved up = scroll up (content follows finger)
                delta  = last_y - event.value
                accum += delta
                ticks  = int(accum / pixels_per_tick)
                if ticks:
                    ui.write(e.EV_REL, e.REL_WHEEL, ticks)
                    ui.syn()
                    accum -= ticks * pixels_per_tick
            last_y = event.value

if __name__ == '__main__':
    main()
