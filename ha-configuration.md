# Home Assistant configuration — TuneoutDisplay v2

v2 needs **no YAML in `configuration.yaml`**. The v1 `rest_command` entries for
`stop-server.py` (port 12345) can be deleted — that server no longer exists.

Each display also writes its own device-specific copy of this page to
`~/smart-display-setup.md` when the installer runs. Examples below use a
device named **Kitchen Display** (`kitchen_display`).

---

## 1. Integrations

| Integration | Needed for | Setup |
|---|---|---|
| MQTT (Mosquitto) | every display | Enable discovery. The device appears on its own |
| ESPHome | displays with a speaker | Add Integration → ESPHome → host `<hostname>.local`, port `6053` |
| Music Assistant 2.7+ | optional | The sendspin player appears on its own |

---

## 2. Entities

MQTT (only what the device's role installed):

| Entity | Role |
|---|---|
| `number.kitchen_display_brightness` | all |
| `switch.kitchen_display_screen` | all |
| `button.kitchen_display_reload_dashboard` | all |
| `text.kitchen_display_dashboard_url` | all |
| `number.kitchen_display_speaker_volume` | speaker present |
| `button.kitchen_display_start_listening` | voice |

From ESPHome (LVA), with a speaker: a `media_player` (TTS / announcements,
with its own volume). Voice role adds `assist_satellite.*` and a mute `switch`.

Entity IDs are derived from names — check the device page if yours differ.
v1's *Voice Volume*, *Media Volume* and *Mic Sensitivity* entities are removed
automatically when a device runs v2.

---

## 3. Lovelace card

1. Copy `lovelace/smart-display-card.js` to `/config/www/smart-display-card.js`.
2. Settings → Dashboards → ⋮ → Resources → Add: `/local/smart-display-card.js`, JavaScript module.
3. Hard-refresh the browser.

```yaml
type: custom:smart-display-card
name: Kitchen Display
brightness_entity: number.kitchen_display_brightness
screen_entity: switch.kitchen_display_screen
# speaker present:
speaker_volume_entity: number.kitchen_display_speaker_volume
media_player_entity: media_player.kitchen_display_media_player
# voice role:
# satellite_entity: assist_satellite.kitchen_display
# mute_entity: switch.kitchen_display_mute
# talk_entity: button.kitchen_display_start_listening
```

All keys except `type` are optional.

---

## 4. Automations

```yaml
automation:
  # Recover all displays after HA restarts (the broker restarts with HA).
  - alias: "Smart displays — reload after HA restart"
    triggers:
      - trigger: homeassistant
        event: start
    actions:
      - delay: "00:00:30"
      - action: button.press
        target:
          entity_id:
            - button.kitchen_display_reload_dashboard

  # Dim at night, restore in the morning.
  - alias: "Kitchen Display — dim at night"
    triggers:
      - trigger: time
        at: "22:00:00"
    actions:
      - action: number.set_value
        target: { entity_id: number.kitchen_display_brightness }
        data: { value: 15 }

  - alias: "Kitchen Display — brighten in the morning"
    triggers:
      - trigger: time
        at: "07:00:00"
    actions:
      - action: number.set_value
        target: { entity_id: number.kitchen_display_brightness }
        data: { value: 100 }

  # Screen off when nobody's home.
  - alias: "Kitchen Display — screen off when away"
    triggers:
      - trigger: state
        entity_id: zone.home
        to: "0"
    actions:
      - action: switch.turn_off
        target: { entity_id: switch.kitchen_display_screen }

  # Announcement through a display with a speaker (LVA output-only).
  - alias: "Doorbell announcement"
    triggers:
      - trigger: state
        entity_id: binary_sensor.doorbell
        to: "on"
    actions:
      - action: tts.speak
        target: { entity_id: tts.piper }
        data:
          media_player_entity_id: media_player.kitchen_display_media_player
          message: "Someone is at the door."
```

---

## 5. Raw MQTT

Dashboard commands go to `smart-display/<device_id>/dashboard/set`:
`reload`, `home`, or any `http(s)://` URL.

```bash
mosquitto_pub -h <broker> -u <user> -P <pass> \
  -t 'smart-display/kitchen_display/dashboard/set' -m reload
```
