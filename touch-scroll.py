#!/usr/bin/env python3
"""touch-scroll

Two-finger swipe gestures → scroll-wheel events via uinput.
Single-finger touches are ignored entirely so tapping, button presses, and
slider dragging all work normally through the compositor's existing
touch-as-pointer emulation.

  Two-finger vertical swipe   → REL_WHEEL  (page scroll, natural direction)
  Two-finger horizontal swipe → REL_HWHEEL (swipe-navigation in HA)

Direction is locked after LOCK_DISTANCE device units of midpoint travel so
a slightly diagonal swipe commits cleanly to one axis.
"""

import time
import evdev
from evdev import InputDevice, UInput, ecodes as e

# ── Tuning ─────────────────────────────────────────────────────────────────────

# Scroll ticks to traverse the full screen height / width.
# Higher = faster; lower = slower.
TICKS_PER_SCREEN = 40

# Midpoint travel (raw device units) before committing to an axis.
LOCK_DISTANCE = 20

DEVICE_NAME_HINT = 'ft5'
RETRY_DELAY = 1
MAX_RETRIES = 30

# ── Device discovery ───────────────────────────────────────────────────────────

def find_touch_device():
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
                if DEVICE_NAME_HINT.lower() in dev.name.lower():
                    print(f"[touch-scroll] Found: {dev.name} ({dev.path})", flush=True)
                    return dev
                candidates.append(dev)
            except Exception:
                pass
        if candidates:
            dev = candidates[0]
            print(f"[touch-scroll] Found: {dev.name} ({dev.path})", flush=True)
            return dev
        print(f"[touch-scroll] No touch device yet, retrying ({attempt+1}/{MAX_RETRIES})…",
              flush=True)
        time.sleep(RETRY_DELAY)
    return None

# ── Main ───────────────────────────────────────────────────────────────────────

def main():
    dev = find_touch_device()
    if dev is None:
        print("[touch-scroll] ERROR: No multitouch device found.", flush=True)
        raise SystemExit(1)

    abs_caps   = dict(dev.capabilities().get(e.EV_ABS, []))
    y_info     = abs_caps.get(e.ABS_MT_POSITION_Y)
    x_info     = abs_caps.get(e.ABS_MT_POSITION_X)
    y_range    = (y_info.max - y_info.min) if y_info else 4095
    x_range    = (x_info.max - x_info.min) if x_info else 4095
    v_per_tick = max(y_range / TICKS_PER_SCREEN, 1)
    h_per_tick = max(x_range / TICKS_PER_SCREEN, 1)

    print(f"[touch-scroll] Y 0–{y_range} ({v_per_tick:.1f}/tick)  "
          f"X 0–{x_range} ({h_per_tick:.1f}/tick)", flush=True)

    ui = UInput(
        {
            e.EV_REL: [e.REL_X, e.REL_Y, e.REL_WHEEL, e.REL_HWHEEL],
            e.EV_KEY: [e.BTN_LEFT, e.BTN_RIGHT, e.BTN_MIDDLE],
        },
        name='touch-scroll-virtual',
        version=0x3,
    )

    # Multitouch slot state — protocol B uses numbered slots
    slots    = {}    # slot_id → {'tid': int, 'x': int, 'y': int}
    cur_slot = 0

    # Two-finger gesture state
    start_x = start_y = None   # midpoint at direction-lock moment
    direction = None            # 'v' | 'h' | None
    accum = 0.0

    print("[touch-scroll] Running — two-finger swipe to scroll/navigate.", flush=True)

    for ev in dev.read_loop():

        # ── Slot selection ─────────────────────────────────────────────────────
        if ev.type == e.EV_ABS and ev.code == e.ABS_MT_SLOT:
            cur_slot = ev.value
            slots.setdefault(cur_slot, {'tid': -1, 'x': 0, 'y': 0})

        # ── Tracking ID (finger down / up) ─────────────────────────────────────
        elif ev.type == e.EV_ABS and ev.code == e.ABS_MT_TRACKING_ID:
            slots.setdefault(cur_slot, {'tid': -1, 'x': 0, 'y': 0})
            slots[cur_slot]['tid'] = ev.value
            if ev.value == -1:
                # Finger lifted — reset gesture if we fall below two fingers
                active = [s for s in slots.values() if s['tid'] != -1]
                if len(active) < 2:
                    start_x = start_y = None
                    direction = None
                    accum = 0.0

        # ── Position updates ───────────────────────────────────────────────────
        elif ev.type == e.EV_ABS and ev.code == e.ABS_MT_POSITION_X:
            slots.setdefault(cur_slot, {'tid': -1, 'x': 0, 'y': 0})
            slots[cur_slot]['x'] = ev.value

        elif ev.type == e.EV_ABS and ev.code == e.ABS_MT_POSITION_Y:
            slots.setdefault(cur_slot, {'tid': -1, 'x': 0, 'y': 0})
            slots[cur_slot]['y'] = ev.value

        # ── Process gesture at sync boundary ───────────────────────────────────
        elif ev.type == e.EV_SYN and ev.code == e.SYN_REPORT:
            active = [s for s in slots.values() if s['tid'] != -1]
            if len(active) != 2:
                continue   # only act on exactly two-finger touches

            # Midpoint of both fingers
            avg_x = (active[0]['x'] + active[1]['x']) / 2
            avg_y = (active[0]['y'] + active[1]['y']) / 2

            if start_x is None:
                start_x, start_y = avg_x, avg_y
                continue

            # Direction lock
            if direction is None:
                dx = abs(avg_x - start_x)
                dy = abs(avg_y - start_y)
                if dx + dy < LOCK_DISTANCE:
                    continue
                direction = 'h' if dx > dy else 'v'
                accum = float(avg_y - start_y) if direction == 'v' \
                        else float(avg_x - start_x)
                start_x, start_y = avg_x, avg_y
                continue

            # Emit events
            if direction == 'v':
                # Swipe down (Y increases) → scroll down (negative wheel)
                accum += avg_y - start_y
                ticks  = int(accum / v_per_tick)
                if ticks:
                    ui.write(e.EV_REL, e.REL_WHEEL, ticks)
                    ui.syn()
                    accum -= ticks * v_per_tick

            elif direction == 'h':
                # Swipe right (X increases) → positive hwheel
                accum += avg_x - start_x
                ticks  = int(accum / h_per_tick)
                if ticks:
                    ui.write(e.EV_REL, e.REL_HWHEEL, ticks)
                    ui.syn()
                    accum -= ticks * h_per_tick

            start_x, start_y = avg_x, avg_y


if __name__ == '__main__':
    main()
