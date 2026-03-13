# Home Assistant Configuration — Smart Display Devices

Covers: **Smart Display Alpha** (`smart-display-alpha.local`) and **Smart Display Beta** (`smart-display-beta.local`)

---

## 1. configuration.yaml

Add to `/config/configuration.yaml` and restart HA.
> Merge into an existing `rest_command:` section if you already have one.

```yaml
rest_command:
  stop_smart_display_alpha:
    url: "http://smart-display-alpha.local:12345/stop"
    method: GET
  stop_smart_display_beta:
    url: "http://smart-display-beta.local:12345/stop"
    method: GET
```

---

## 2. Custom Lovelace Card

### Install the card resource

1. Save `smart-display-card.js` (below) to `/config/www/smart-display-card.js` on your HA instance
2. In HA: **Settings → Dashboards → ⋮ → Resources → + Add Resource**
   - URL: `/local/smart-display-card.js`
   - Resource type: JavaScript module
3. Hard-refresh the browser (`Ctrl+Shift+R`)

### Card YAML — Smart Display Alpha

In a Lovelace dashboard: **Edit → + Add Card → Manual**, paste:

```yaml
type: custom:smart-display-card
name: Smart Display Alpha
satellite_entity: assist_satellite.smart_display_alpha
tts_volume_entity: number.smart_display_alpha_tts_volume
media_volume_entity: number.smart_display_alpha_media_volume
stop_entity: button.smart_display_alpha_stop_tts
```

### Card YAML — Smart Display Beta

```yaml
type: custom:smart-display-card
name: Smart Display Beta
satellite_entity: assist_satellite.smart_display_beta
tts_volume_entity: number.smart_display_beta_tts_volume
media_volume_entity: number.smart_display_beta_media_volume
stop_entity: button.smart_display_beta_stop_tts
```

> **Note on entity IDs:** Verify the exact entity IDs in HA under **Settings → Devices & Services**.
> The `assist_satellite.*` entity is created when you add the ESPHome integration and click
> "Set Up Voice Assistant". The `number.*` and `button.*` entities come from the MQTT bridge.

---

## 3. smart-display-card.js

Save this file to `/config/www/smart-display-card.js`:

```javascript
/**
 * smart-display-card.js
 * Custom Lovelace card for Smart Display device control.
 *
 * Config example:
 *   type: custom:smart-display-card
 *   name: Smart Display Alpha
 *   satellite_entity: assist_satellite.smart_display_alpha
 *   tts_volume_entity: number.smart_display_alpha_tts_volume
 *   media_volume_entity: number.smart_display_alpha_media_volume
 *   stop_entity: button.smart_display_alpha_stop_tts
 */

(() => {
  class SmartDisplayCard extends HTMLElement {
    constructor() {
      super();
      this.attachShadow({ mode: 'open' });
      this._config      = null;
      this._hass        = null;
      this._built       = false;
      this._ttsActive   = false;
      this._mediaActive = false;
    }

    setConfig(config) {
      if (!config.satellite_entity)    throw new Error('smart-display-card: satellite_entity is required');
      if (!config.tts_volume_entity)   throw new Error('smart-display-card: tts_volume_entity is required');
      if (!config.media_volume_entity) throw new Error('smart-display-card: media_volume_entity is required');
      this._config = { name: 'Smart Display', ...config };
      if (this._hass) this._ensureBuilt();
    }

    set hass(hass) {
      this._hass = hass;
      this._ensureBuilt();
      this._update();
    }

    getCardSize() { return 3; }

    static getStubConfig() {
      return {
        satellite_entity:    'assist_satellite.smart_display',
        tts_volume_entity:   'number.smart_display_tts_volume',
        media_volume_entity: 'number.smart_display_media_volume',
        stop_entity:         'button.smart_display_stop_tts',
      };
    }

    _ensureBuilt() {
      if (this._built || !this._config || !this._hass) return;
      this._buildDOM();
      this._built = true;
    }

    _buildDOM() {
      const ttsVol   = this._vol(this._config.tts_volume_entity,   90);
      const mediaVol = this._vol(this._config.media_volume_entity, 75);

      this.shadowRoot.innerHTML = `
        <style>${this._css()}</style>
        <ha-card>
          <div class="card-content">

            <div class="header">
              <span class="name">${this._config.name}</span>
              <span class="status-chip" id="chip">
                <span class="dot" id="dot"></span>
                <span id="status-label">Standby</span>
              </span>
            </div>

            <div class="slider-row">
              <ha-icon icon="mdi:microphone" title="Assistant volume"></ha-icon>
              <span class="label">Assistant</span>
              <input type="range" id="tts-slider" min="0" max="100" value="${ttsVol}">
              <span class="vol-val" id="tts-val">${Math.round(ttsVol)}%</span>
            </div>

            <div class="slider-row">
              <ha-icon icon="mdi:music-note" title="Media volume"></ha-icon>
              <span class="label">Media</span>
              <input type="range" id="media-slider" min="0" max="100" value="${mediaVol}">
              <span class="vol-val" id="media-val">${Math.round(mediaVol)}%</span>
            </div>

          </div>
        </ha-card>
      `;

      this._bindEvents();
    }

    _bindEvents() {
      this.shadowRoot.getElementById('chip')
        .addEventListener('click', () => this._stopAction());

      const ttsSlider = this.shadowRoot.getElementById('tts-slider');
      const ttsVal    = this.shadowRoot.getElementById('tts-val');
      ttsSlider.addEventListener('pointerdown', () => { this._ttsActive = true; });
      ttsSlider.addEventListener('input',  (e) => { ttsVal.textContent = e.target.value + '%'; });
      ttsSlider.addEventListener('change', (e) => {
        this._setVolume(this._config.tts_volume_entity, parseInt(e.target.value));
        this._ttsActive = false;
      });
      ttsSlider.addEventListener('pointerup', () => { this._ttsActive = false; });

      const mediaSlider = this.shadowRoot.getElementById('media-slider');
      const mediaVal    = this.shadowRoot.getElementById('media-val');
      mediaSlider.addEventListener('pointerdown', () => { this._mediaActive = true; });
      mediaSlider.addEventListener('input',  (e) => { mediaVal.textContent = e.target.value + '%'; });
      mediaSlider.addEventListener('change', (e) => {
        this._setVolume(this._config.media_volume_entity, parseInt(e.target.value));
        this._mediaActive = false;
      });
      mediaSlider.addEventListener('pointerup', () => { this._mediaActive = false; });
    }

    _update() {
      if (!this._built) return;

      const status   = this._status();
      const isActive = status === 'listening' || status === 'responding';

      const LABELS = { standby: 'Standby', listening: 'Listening…', responding: 'Responding…', unknown: 'Unknown' };
      const COLORS = {
        standby:    'var(--secondary-text-color)',
        listening:  'var(--success-color,  #4CAF50)',
        responding: 'var(--info-color,     #03a9f4)',
        unknown:    'var(--error-color,    #f44336)',
      };
      const color = COLORS[status] ?? COLORS.unknown;

      const chip  = this.shadowRoot.getElementById('chip');
      const dot   = this.shadowRoot.getElementById('dot');
      const label = this.shadowRoot.getElementById('status-label');

      label.textContent      = LABELS[status] ?? status;
      chip.style.color       = color;
      chip.style.borderColor = color;
      chip.style.cursor      = isActive ? 'pointer' : 'default';
      chip.title             = isActive ? 'Tap to stop' : '';
      dot.style.background   = color;
      dot.classList.toggle('pulse', status !== 'standby' && status !== 'unknown');

      if (!this._ttsActive) {
        const v = this._vol(this._config.tts_volume_entity, 90);
        this.shadowRoot.getElementById('tts-slider').value = v;
        this.shadowRoot.getElementById('tts-val').textContent = Math.round(v) + '%';
      }
      if (!this._mediaActive) {
        const v = this._vol(this._config.media_volume_entity, 75);
        this.shadowRoot.getElementById('media-slider').value = v;
        this.shadowRoot.getElementById('media-val').textContent = Math.round(v) + '%';
      }
    }

    _status() {
      const state = this._hass?.states[this._config.satellite_entity]?.state;
      if (!state)                                            return 'unknown';
      if (state === 'idle')                                  return 'standby';
      if (state === 'listening')                             return 'listening';
      if (state === 'processing' || state === 'responding')  return 'responding';
      return 'unknown';
    }

    _vol(entityId, fallback) {
      return parseFloat(this._hass?.states[entityId]?.state ?? fallback);
    }

    _stopAction() {
      const s = this._status();
      if (s !== 'listening' && s !== 'responding') return;
      if (this._config.stop_entity) {
        this._hass.callService('button', 'press', { entity_id: this._config.stop_entity });
      }
    }

    _setVolume(entityId, value) {
      this._hass.callService('number', 'set_value', { entity_id: entityId, value });
    }

    _css() {
      return `
        :host { display: block; }
        .card-content { padding: 16px 16px 10px; }
        .header {
          display: flex;
          align-items: center;
          justify-content: space-between;
          margin-bottom: 18px;
        }
        .name {
          font-size: 1.05em;
          font-weight: 500;
          color: var(--primary-text-color);
        }
        .status-chip {
          display: inline-flex;
          align-items: center;
          gap: 6px;
          padding: 4px 11px;
          border-radius: 14px;
          font-size: 0.8em;
          font-weight: 500;
          border: 1.5px solid;
          transition: color 0.3s, border-color 0.3s, opacity 0.15s;
          user-select: none;
        }
        .status-chip:hover { opacity: 0.72; }
        .dot {
          width: 7px;
          height: 7px;
          border-radius: 50%;
          flex-shrink: 0;
          transition: background 0.3s;
        }
        .dot.pulse { animation: pulse 1.6s ease-in-out infinite; }
        @keyframes pulse {
          0%, 100% { opacity: 1; }
          50%       { opacity: 0.2; }
        }
        .slider-row {
          display: flex;
          align-items: center;
          gap: 10px;
          margin-bottom: 14px;
        }
        .label {
          font-size: 0.86em;
          color: var(--secondary-text-color);
          min-width: 62px;
        }
        .vol-val {
          font-size: 0.82em;
          color: var(--secondary-text-color);
          min-width: 36px;
          text-align: right;
        }
        ha-icon {
          color: var(--secondary-text-color);
          --mdc-icon-size: 18px;
          flex-shrink: 0;
        }
        input[type=range] {
          flex: 1;
          height: 4px;
          border-radius: 2px;
          -webkit-appearance: none;
          appearance: none;
          background: var(--secondary-background-color, #e0e0e0);
          outline: none;
          cursor: pointer;
        }
        input[type=range]::-webkit-slider-thumb {
          -webkit-appearance: none;
          width: 18px;
          height: 18px;
          border-radius: 50%;
          background: var(--primary-color);
          cursor: pointer;
          box-shadow: 0 1px 4px rgba(0,0,0,0.25);
        }
        input[type=range]::-moz-range-thumb {
          width: 18px;
          height: 18px;
          border-radius: 50%;
          background: var(--primary-color);
          cursor: pointer;
          border: none;
          box-shadow: 0 1px 4px rgba(0,0,0,0.25);
        }
      `;
    }
  }

  if (!customElements.get('smart-display-card')) {
    customElements.define('smart-display-card', SmartDisplayCard);
  }
})();
```

---

## 4. Automations

Paste into `/config/automations.yaml`, or add via **Settings → Automations → + Create → Edit in YAML**.

```yaml
# ── Smart Display Alpha ───────────────────────────────────────────────────────

- alias: "Smart Display Alpha — Dim at night"
  trigger:
    - platform: time
      at: "22:00:00"
  action:
    - action: number.set_value
      target:
        entity_id: number.smart_display_alpha_brightness
      data:
        value: 15

- alias: "Smart Display Alpha — Brighten in morning"
  trigger:
    - platform: time
      at: "07:00:00"
  action:
    - action: number.set_value
      target:
        entity_id: number.smart_display_alpha_brightness
      data:
        value: 100

- alias: "Smart Display Alpha — Stop TTS on media start"
  description: "Clears any in-progress TTS when music starts playing"
  trigger:
    - platform: state
      entity_id: media_player.smart_display_alpha  # verify entity in HA
      to: "playing"
  action:
    - action: rest_command.stop_smart_display_alpha

# ── Smart Display Beta ────────────────────────────────────────────────────────

- alias: "Smart Display Beta — Dim at night"
  trigger:
    - platform: time
      at: "22:00:00"
  action:
    - action: number.set_value
      target:
        entity_id: number.smart_display_beta_brightness
      data:
        value: 15

- alias: "Smart Display Beta — Brighten in morning"
  trigger:
    - platform: time
      at: "07:00:00"
  action:
    - action: number.set_value
      target:
        entity_id: number.smart_display_beta_brightness
      data:
        value: 100

- alias: "Smart Display Beta — Stop TTS on media start"
  description: "Clears any in-progress TTS when music starts playing"
  trigger:
    - platform: state
      entity_id: media_player.smart_display_beta  # verify entity in HA
      to: "playing"
  action:
    - action: rest_command.stop_smart_display_beta
```

---

## 5. Entity ID Reference

Verify actual IDs in HA under **Settings → Devices & Services → [MQTT / ESPHome]**.

| Device | Entity | Expected ID |
|--------|--------|-------------|
| Alpha | Assist Satellite | `assist_satellite.smart_display_alpha` |
| Alpha | TTS Volume | `number.smart_display_alpha_tts_volume` |
| Alpha | Media Volume | `number.smart_display_alpha_media_volume` |
| Alpha | Brightness | `number.smart_display_alpha_brightness` |
| Alpha | Stop TTS | `button.smart_display_alpha_stop_tts` |
| Beta | Assist Satellite | `assist_satellite.smart_display_beta` |
| Beta | TTS Volume | `number.smart_display_beta_tts_volume` |
| Beta | Media Volume | `number.smart_display_beta_media_volume` |
| Beta | Brightness | `number.smart_display_beta_brightness` |
| Beta | Stop TTS | `button.smart_display_beta_stop_tts` |
