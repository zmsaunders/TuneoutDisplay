/**
 * smart-display-card.js
 * Custom Lovelace card for Smart Display device control.
 *
 * Config example:
 *   type: custom:smart-display-card
 *   name: Smart Display               # optional, defaults to "Smart Display"
 *   satellite_entity: assist_satellite.smart_display
 *   tts_volume_entity: number.smart_display_tts_volume
 *   media_volume_entity: number.smart_display_media_volume
 *   brightness_entity: number.smart_display_brightness
 *   mute_entity: switch.smart_display_mute   # optional — enables chip tap to mute
 *   mic_gain_entity: number.smart_display_mic_gain   # optional
 */

(() => {
  class SmartDisplayCard extends HTMLElement {
    constructor() {
      super();
      this.attachShadow({ mode: 'open' });
      this._config  = null;
      this._hass    = null;
      this._built   = false;
      this._ttsActive        = false; // true while user is dragging TTS slider
      this._mediaActive      = false; // true while user is dragging Media slider
      this._brightnessActive = false; // true while user is dragging Brightness slider
      this._micActive        = false; // true while user is dragging Mic Sensitivity slider
    }

    // ── Lovelace lifecycle ─────────────────────────────────────────────────

    setConfig(config) {
      if (!config.satellite_entity)   throw new Error('smart-display-card: satellite_entity is required');
      if (!config.tts_volume_entity)  throw new Error('smart-display-card: tts_volume_entity is required');
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
        brightness_entity:   'number.smart_display_brightness',
        mute_entity:         'switch.smart_display_mute',
      };
    }

    // ── DOM construction (once) ────────────────────────────────────────────

    _ensureBuilt() {
      if (this._built || !this._config || !this._hass) return;
      this._buildDOM();
      this._built = true;
    }

    _buildDOM() {
      const ttsVol    = this._vol(this._config.tts_volume_entity,   90);
      const mediaVol  = this._vol(this._config.media_volume_entity, 75);
      const brightness = this._vol(this._config.brightness_entity,  80);

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

            <div class="slider-row">
              <ha-icon icon="mdi:brightness-6" title="Brightness"></ha-icon>
              <span class="label">Brightness</span>
              <input type="range" id="brightness-slider" min="5" max="100" value="${brightness}">
              <span class="vol-val" id="brightness-val">${Math.round(brightness)}%</span>
            </div>

            ${this._config.mic_gain_entity ? `
            <div class="slider-row">
              <ha-icon icon="mdi:microphone-settings" title="Mic sensitivity"></ha-icon>
              <span class="label">Mic Sensitivity</span>
              <input type="range" id="mic-slider" min="0" max="100" value="${this._vol(this._config.mic_gain_entity, 63)}">
              <span class="vol-val" id="mic-val">${Math.round(this._vol(this._config.mic_gain_entity, 63))}%</span>
            </div>` : ''}

          </div>
        </ha-card>
      `;

      this._bindEvents();
    }

    _bindEvents() {
      // Status chip → mute toggle
      this.shadowRoot.getElementById('chip')
        .addEventListener('click', () => this._chipAction());

      // TTS slider
      const ttsSlider = this.shadowRoot.getElementById('tts-slider');
      const ttsVal    = this.shadowRoot.getElementById('tts-val');

      ttsSlider.addEventListener('pointerdown', () => { this._ttsActive = true; });
      ttsSlider.addEventListener('input',  (e) => { ttsVal.textContent = e.target.value + '%'; });
      ttsSlider.addEventListener('change', (e) => {
        this._setVolume(this._config.tts_volume_entity, parseInt(e.target.value));
        this._ttsActive = false;
      });
      ttsSlider.addEventListener('pointerup', () => { this._ttsActive = false; });

      // Media slider
      const mediaSlider = this.shadowRoot.getElementById('media-slider');
      const mediaVal    = this.shadowRoot.getElementById('media-val');

      mediaSlider.addEventListener('pointerdown', () => { this._mediaActive = true; });
      mediaSlider.addEventListener('input',  (e) => { mediaVal.textContent = e.target.value + '%'; });
      mediaSlider.addEventListener('change', (e) => {
        this._setVolume(this._config.media_volume_entity, parseInt(e.target.value));
        this._mediaActive = false;
      });
      mediaSlider.addEventListener('pointerup', () => { this._mediaActive = false; });

      // Brightness slider
      const brightnessSlider = this.shadowRoot.getElementById('brightness-slider');
      const brightnessVal    = this.shadowRoot.getElementById('brightness-val');

      brightnessSlider.addEventListener('pointerdown', () => { this._brightnessActive = true; });
      brightnessSlider.addEventListener('input',  (e) => { brightnessVal.textContent = e.target.value + '%'; });
      brightnessSlider.addEventListener('change', (e) => {
        this._setVolume(this._config.brightness_entity, parseInt(e.target.value));
        this._brightnessActive = false;
      });
      brightnessSlider.addEventListener('pointerup', () => { this._brightnessActive = false; });

      // Mic Sensitivity slider (optional — only bound if entity is configured)
      if (this._config.mic_gain_entity) {
        const micSlider = this.shadowRoot.getElementById('mic-slider');
        const micVal    = this.shadowRoot.getElementById('mic-val');

        micSlider.addEventListener('pointerdown', () => { this._micActive = true; });
        micSlider.addEventListener('input',  (e) => { micVal.textContent = e.target.value + '%'; });
        micSlider.addEventListener('change', (e) => {
          this._setVolume(this._config.mic_gain_entity, parseInt(e.target.value));
          this._micActive = false;
        });
        micSlider.addEventListener('pointerup', () => { this._micActive = false; });
      }
    }

    // ── Incremental updates (every hass change) ────────────────────────────

    _update() {
      if (!this._built) return;

      // Status chip
      const status = this._status();

      const LABELS = {
        standby:   'Standby',
        listening: 'Listening…',
        responding:'Responding…',
        muted:     'Muted',
        unknown:   'Unknown',
      };
      const COLORS = {
        standby:   'var(--secondary-text-color)',
        listening: 'var(--success-color,  #4CAF50)',
        responding:'var(--info-color,     #03a9f4)',
        muted:     'var(--warning-color,  #FF9800)',
        unknown:   'var(--error-color,    #f44336)',
      };
      const color      = COLORS[status] ?? COLORS.unknown;
      const canMute    = !!this._config.mute_entity;
      const muteTitle  = status === 'muted' ? 'Tap to unmute' : 'Tap to mute';

      const chip  = this.shadowRoot.getElementById('chip');
      const dot   = this.shadowRoot.getElementById('dot');
      const label = this.shadowRoot.getElementById('status-label');

      label.textContent        = LABELS[status] ?? status;
      chip.style.color         = color;
      chip.style.borderColor   = color;
      chip.style.cursor        = canMute ? 'pointer' : 'default';
      chip.title               = canMute ? muteTitle : '';
      dot.style.background     = color;
      dot.classList.toggle('pulse', status !== 'standby' && status !== 'muted' && status !== 'unknown');

      // Sliders — only update if user is not currently dragging
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
      if (!this._brightnessActive) {
        const v = this._vol(this._config.brightness_entity, 80);
        this.shadowRoot.getElementById('brightness-slider').value = v;
        this.shadowRoot.getElementById('brightness-val').textContent = Math.round(v) + '%';
      }
      if (this._config.mic_gain_entity && !this._micActive) {
        const v = this._vol(this._config.mic_gain_entity, 63);
        const s = this.shadowRoot.getElementById('mic-slider');
        if (s) {
          s.value = v;
          this.shadowRoot.getElementById('mic-val').textContent = Math.round(v) + '%';
        }
      }
    }

    // ── Helpers ────────────────────────────────────────────────────────────

    _status() {
      // Muted takes visual priority — show it regardless of pipeline state.
      if (this._config.mute_entity) {
        const muteState = this._hass?.states[this._config.mute_entity]?.state;
        if (muteState === 'on') return 'muted';
      }
      const state = this._hass?.states[this._config.satellite_entity]?.state;
      if (!state) return 'unknown';
      if (state === 'idle')                                 return 'standby';
      if (state === 'listening')                            return 'listening';
      if (state === 'processing' || state === 'responding') return 'responding';
      return 'unknown';
    }

    _vol(entityId, fallback) {
      return parseFloat(this._hass?.states[entityId]?.state ?? fallback);
    }

    _chipAction() {
      if (!this._config.mute_entity) return;
      const isMuted  = this._hass?.states[this._config.mute_entity]?.state === 'on';
      const service  = isMuted ? 'turn_off' : 'turn_on';
      this._hass.callService('switch', service, { entity_id: this._config.mute_entity });
    }

    _setVolume(entityId, value) {
      this._hass.callService('number', 'set_value', { entity_id: entityId, value });
    }

    // ── Styles ─────────────────────────────────────────────────────────────

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

        /* Status chip */
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

        /* Slider rows */
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

        /* Range input */
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
