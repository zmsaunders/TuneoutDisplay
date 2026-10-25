/**
 * smart-display-card.js — TuneoutDisplay v2 Lovelace card.
 *
 * Every entity is optional; rows appear only for what you configure, so the
 * same card works for the display role (brightness only), display + speaker,
 * and the voice role.
 *
 *   type: custom:smart-display-card
 *   name: Kitchen Display                                  # optional
 *   brightness_entity: number.kitchen_display_brightness   # slider, min 5 on the card
 *   screen_entity: switch.kitchen_display_screen           # header power toggle
 *   speaker_volume_entity: number.kitchen_display_speaker_volume  # master volume
 *   media_player_entity: media_player.kitchen_display_media_player  # LVA volume
 *   satellite_entity: assist_satellite.kitchen_display     # voice role: status chip
 *   mute_entity: switch.kitchen_display_mute               # voice role: tap chip to mute
 *   talk_entity: button.kitchen_display_start_listening    # voice role: talk button
 */

(() => {
  // Slider rows, in display order. kind: 'number' (0–100 entity state) or
  // 'media' (media_player volume_level 0–1).
  const SLIDERS = [
    { key: 'speaker_volume_entity', kind: 'number', icon: 'mdi:volume-high',    label: 'Speaker',    min: 0 },
    { key: 'media_player_entity',   kind: 'media',  icon: 'mdi:account-voice',  label: 'Assistant',  min: 0 },
    // Card-enforced min 5 so a stray drag can't black the screen (entity min is 0).
    { key: 'brightness_entity',     kind: 'number', icon: 'mdi:brightness-6',   label: 'Brightness', min: 5 },
  ];

  class SmartDisplayCard extends HTMLElement {
    constructor() {
      super();
      this.attachShadow({ mode: 'open' });
      this._config = null;
      this._hass = null;
      this._built = false;
      this._dragging = new Set(); // slider keys the user is currently dragging
    }

    setConfig(config) {
      this._config = { name: 'Smart Display', ...config };
      this._built = false;
      if (this._hass) { this._ensureBuilt(); this._update(); }
    }

    set hass(hass) {
      this._hass = hass;
      this._ensureBuilt();
      this._update();
    }

    getCardSize() { return 1 + this._sliders().length; }

    static getStubConfig() {
      return { name: 'Smart Display', brightness_entity: 'number.smart_display_brightness' };
    }

    // ── Build (once per config) ────────────────────────────────────────────

    _sliders() { return SLIDERS.filter((s) => this._config?.[s.key]); }

    _ensureBuilt() {
      if (this._built || !this._config || !this._hass) return;
      const c = this._config;
      const rows = this._sliders().map((s) => `
        <div class="slider-row">
          <ha-icon icon="${s.icon}"></ha-icon>
          <span class="label">${s.label}</span>
          <input type="range" id="${s.key}" min="${s.min}" max="100" value="${this._value(s)}">
          <span class="val" id="${s.key}-val">${this._value(s)}%</span>
        </div>`).join('');

      this.shadowRoot.innerHTML = `
        <style>${this._css()}</style>
        <ha-card>
          <div class="card-content">
            <div class="header">
              <span class="name">${this._escape(c.name)}</span>
              <span class="actions">
                ${c.talk_entity ? '<ha-icon-button id="talk" title="Talk"><ha-icon icon="mdi:microphone-message"></ha-icon></ha-icon-button>' : ''}
                ${c.screen_entity ? '<ha-icon-button id="screen" title="Screen on/off"><ha-icon id="screen-icon" icon="mdi:monitor"></ha-icon></ha-icon-button>' : ''}
                ${c.satellite_entity ? '<span class="chip" id="chip"><span class="dot" id="dot"></span><span id="chip-label">Standby</span></span>' : ''}
              </span>
            </div>
            ${rows}
          </div>
        </ha-card>`;

      this._bind();
      this._built = true;
    }

    _bind() {
      const $ = (id) => this.shadowRoot.getElementById(id);
      const c = this._config;

      for (const s of this._sliders()) {
        const el = $(s.key);
        const val = $(`${s.key}-val`);
        el.addEventListener('pointerdown', () => this._dragging.add(s.key));
        el.addEventListener('pointerup', () => this._dragging.delete(s.key));
        el.addEventListener('input', (e) => { val.textContent = `${e.target.value}%`; });
        el.addEventListener('change', (e) => {
          this._set(s, parseInt(e.target.value, 10));
          this._dragging.delete(s.key);
        });
      }

      if (c.talk_entity) {
        $('talk').addEventListener('click', () =>
          this._hass.callService('button', 'press', { entity_id: c.talk_entity }));
      }
      if (c.screen_entity) {
        $('screen').addEventListener('click', () =>
          this._hass.callService('switch', 'toggle', { entity_id: c.screen_entity }));
      }
      if (c.satellite_entity && c.mute_entity) {
        $('chip').addEventListener('click', () =>
          this._hass.callService('switch', 'toggle', { entity_id: c.mute_entity }));
      }
    }

    // ── Update (every hass change) ─────────────────────────────────────────

    _update() {
      if (!this._built) return;
      const $ = (id) => this.shadowRoot.getElementById(id);
      const c = this._config;

      for (const s of this._sliders()) {
        if (this._dragging.has(s.key)) continue; // don't fight the user's finger
        const v = this._value(s);
        $(s.key).value = v;
        $(`${s.key}-val`).textContent = `${v}%`;
      }

      if (c.screen_entity) {
        const on = this._state(c.screen_entity) !== 'off';
        $('screen-icon').setAttribute('icon', on ? 'mdi:monitor' : 'mdi:monitor-off');
      }

      if (c.satellite_entity) {
        const status = this._status();
        const LABELS = { standby: 'Standby', listening: 'Listening…', responding: 'Responding…', muted: 'Muted', unknown: 'Unknown' };
        const COLORS = {
          standby: 'var(--secondary-text-color)',
          listening: 'var(--success-color, #4CAF50)',
          responding: 'var(--info-color, #03a9f4)',
          muted: 'var(--warning-color, #FF9800)',
          unknown: 'var(--error-color, #f44336)',
        };
        const color = COLORS[status];
        const chip = $('chip');
        $('chip-label').textContent = LABELS[status];
        chip.style.color = color;
        chip.style.borderColor = color;
        chip.style.cursor = c.mute_entity ? 'pointer' : 'default';
        chip.title = c.mute_entity ? (status === 'muted' ? 'Tap to unmute' : 'Tap to mute') : '';
        $('dot').style.background = color;
        $('dot').classList.toggle('pulse', status === 'listening' || status === 'responding');
      }
    }

    // ── Helpers ────────────────────────────────────────────────────────────

    _state(id) { return this._hass?.states[id]?.state; }

    _value(s) {
      const st = this._hass?.states[this._config[s.key]];
      if (!st) return 0;
      const v = s.kind === 'media'
        ? Number(st.attributes?.volume_level ?? 0) * 100
        : parseFloat(st.state);
      return Number.isFinite(v) ? Math.round(v) : 0;
    }

    _set(s, value) {
      const entity_id = this._config[s.key];
      if (s.kind === 'media') {
        this._hass.callService('media_player', 'volume_set', { entity_id, volume_level: value / 100 });
      } else {
        this._hass.callService('number', 'set_value', { entity_id, value });
      }
    }

    _status() {
      const c = this._config;
      if (c.mute_entity && this._state(c.mute_entity) === 'on') return 'muted';
      const st = this._state(c.satellite_entity);
      if (st === 'idle') return 'standby';
      if (st === 'listening') return 'listening';
      if (st === 'processing' || st === 'responding') return 'responding';
      return 'unknown';
    }

    _escape(s) {
      return String(s).replace(/[&<>"']/g, (ch) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[ch]));
    }

    _css() {
      return `
        :host { display: block; }
        .card-content { padding: 16px 16px 10px; }
        .header { display: flex; align-items: center; justify-content: space-between; margin-bottom: 14px; min-height: 40px; }
        .name { font-size: 1.05em; font-weight: 500; color: var(--primary-text-color); }
        .actions { display: inline-flex; align-items: center; gap: 4px; }
        ha-icon-button { color: var(--secondary-text-color); --mdc-icon-button-size: 36px; }
        .chip {
          display: inline-flex; align-items: center; gap: 6px; padding: 4px 11px;
          border-radius: 14px; font-size: 0.8em; font-weight: 500; border: 1.5px solid;
          transition: color 0.3s, border-color 0.3s; user-select: none;
        }
        .dot { width: 7px; height: 7px; border-radius: 50%; flex-shrink: 0; }
        .dot.pulse { animation: pulse 1.6s ease-in-out infinite; }
        @keyframes pulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.2; } }
        .slider-row { display: flex; align-items: center; gap: 10px; margin-bottom: 14px; }
        .label { font-size: 0.86em; color: var(--secondary-text-color); min-width: 72px; }
        .val { font-size: 0.82em; color: var(--secondary-text-color); min-width: 36px; text-align: right; }
        .slider-row ha-icon { color: var(--secondary-text-color); --mdc-icon-size: 18px; flex-shrink: 0; }
        input[type=range] {
          flex: 1; height: 4px; border-radius: 2px; -webkit-appearance: none; appearance: none;
          background: var(--secondary-background-color, #e0e0e0); outline: none; cursor: pointer;
        }
        input[type=range]::-webkit-slider-thumb {
          -webkit-appearance: none; width: 18px; height: 18px; border-radius: 50%;
          background: var(--primary-color); box-shadow: 0 1px 4px rgba(0,0,0,0.25);
        }
        input[type=range]::-moz-range-thumb {
          width: 18px; height: 18px; border-radius: 50%; border: none;
          background: var(--primary-color); box-shadow: 0 1px 4px rgba(0,0,0,0.25);
        }
      `;
    }
  }

  if (!customElements.get('smart-display-card')) {
    customElements.define('smart-display-card', SmartDisplayCard);
  }
})();
