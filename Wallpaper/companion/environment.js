// Shared environment model: time of day, weather and per-scene light.
// Both the background page and the character page import this, so Miku is lit
// by exactly the same sky, weather and lightning as the scene behind her.

export const WEATHER_KINDS = ['clear', 'cloudy', 'fog', 'rain', 'storm', 'snow'];

// How each kind of weather changes the light (blended in by intensity).
const WEATHER_LIGHT = {
  clear: { key: 1, ambient: 1, fill: 1, tint: [1, 1, 1], shadow: 1 },
  cloudy: { key: 0.62, ambient: 0.98, fill: 1.08, tint: [0.94, 0.96, 1], shadow: 0.55 },
  fog: { key: 0.5, ambient: 1.02, fill: 1.12, tint: [0.95, 0.97, 1], shadow: 0.35 },
  rain: { key: 0.48, ambient: 0.86, fill: 1.02, tint: [0.84, 0.9, 1], shadow: 0.45 },
  storm: { key: 0.36, ambient: 0.74, fill: 0.96, tint: [0.78, 0.84, 1], shadow: 0.3 },
  snow: { key: 0.62, ambient: 1.06, fill: 1.12, tint: [0.95, 0.98, 1.04], shadow: 0.5 }
};

// Per-scene colour casts. `indoor` scenes feel weather only through the windows.
export const SCENE_LIGHT = {
  // Hachikō gates: fluorescent station light, so the time of day shows only faintly.
  shibuya: { indoor: true, day: [1, 1, 1.03], dusk: [1.03, 0.98, 0.95], night: [0.98, 0.99, 1.05], rim: [0.7, 1, 0.75] },
  ikebukuro: { indoor: false, day: [1.05, 1.0, 0.94], dusk: [1.06, 0.94, 0.9], night: [0.98, 0.96, 1.04], rim: [1, 0.92, 0.8] },
  akihabara: { indoor: false, day: [1, 1, 1.02], dusk: [1.06, 0.92, 1.0], night: [1.06, 0.86, 1.08], rim: [0.6, 1, 1] },
  shinjuku: { indoor: false, day: [1, 1.0, 1.02], dusk: [1.05, 0.95, 0.92], night: [0.94, 0.98, 1.08], rim: [0.85, 0.92, 1] },
  hallway: { indoor: true, day: [1.06, 1.0, 0.9], dusk: [1.08, 0.92, 0.82], night: [0.98, 1.0, 1.04], rim: [1, 0.9, 0.75] },
  musicroom: { indoor: true, day: [1.02, 0.96, 1.05], dusk: [1.06, 0.9, 0.98], night: [0.98, 0.98, 1.06], rim: [1, 0.85, 1] }
};

const DEFAULT_WEATHER = { kind: 'clear', intensity: 0, wind: 0.15, cloud: 0.15 };

export function normalizeWeather(input) {
  const kind = WEATHER_KINDS.includes(input?.kind) ? input.kind : 'clear';
  const clamp = (value, min, max, fallback) => {
    const number = Number(value);
    return Number.isFinite(number) ? Math.min(max, Math.max(min, number)) : fallback;
  };
  return {
    kind,
    intensity: kind === 'clear' ? 0 : clamp(input?.intensity, 0, 1, 0.6),
    wind: clamp(input?.wind, -1, 1, DEFAULT_WEATHER.wind),
    cloud: clamp(input?.cloud, 0, 1, kind === 'clear' ? 0.15 : 0.8)
  };
}

export function defaultWeather() {
  return { ...DEFAULT_WEATHER };
}

// ---- Sun ---------------------------------------------------------------

/** Day / dusk / night anchors built from sunrise and sunset (local hours). */
export function timeAnchors(sunrise = 6.0, sunset = 17.75) {
  const rise = Math.min(Math.max(sunrise, 4), 8.5);
  const set = Math.min(Math.max(sunset, 15.5), 20.5);
  return [
    { hour: 0, weights: { day: 0, dusk: 0, night: 1 } },
    { hour: rise - 0.6, weights: { day: 0, dusk: 0, night: 1 } },
    { hour: rise + 0.4, weights: { day: 0, dusk: 1, night: 0 } },
    { hour: rise + 1.8, weights: { day: 1, dusk: 0, night: 0 } },
    { hour: set - 1.6, weights: { day: 1, dusk: 0, night: 0 } },
    { hour: set, weights: { day: 0, dusk: 1, night: 0 } },
    { hour: set + 1.3, weights: { day: 0, dusk: 0, night: 1 } },
    { hour: 24, weights: { day: 0, dusk: 0, night: 1 } }
  ];
}

/** Sun direction in the companion's world space (x: left/right, y: up, z: towards camera). */
export function sunDirection(hour, sunrise = 6, sunset = 17.75) {
  const span = Math.max(1, sunset - sunrise);
  const progress = (hour - sunrise) / span; // 0 at sunrise, 1 at sunset
  const clamped = Math.min(1.1, Math.max(-0.1, progress));
  const elevation = Math.max(0.12, Math.sin(Math.PI * Math.min(1, Math.max(0, clamped))));
  return {
    x: (clamped - 0.5) * 2 * 20, // morning from the left, afternoon from the right
    y: 6 + elevation * 18,
    z: 14 + elevation * 6
  };
}

// ---- Lightning (deterministic so both pages flash together) -------------

function hash(value) {
  const x = Math.sin(value * 127.1 + 311.7) * 43758.5453;
  return x - Math.floor(x);
}

/** 0..1 brightness of a lightning flash at `nowMs` (wall clock). */
export function lightningFlash(nowMs, weather) {
  if (weather.kind !== 'storm') return 0;
  const slotLength = 9000;
  const slot = Math.floor(nowMs / slotLength);
  if (hash(slot) > 0.25 + weather.intensity * 0.3) return 0;
  const strikeAt = slot * slotLength + 1200 + hash(slot + 0.5) * 6500;
  const t = (nowMs - strikeAt) / 1000;
  if (t < 0 || t > 0.9) return 0;
  if (t < 0.07) return 1;
  if (t < 0.13) return 0.25;
  if (t < 0.2) return 0.75;
  return Math.max(0, 0.75 * (1 - (t - 0.2) / 0.7));
}

// ---- Character lighting ------------------------------------------------

function mix3(a, b, t) {
  return [0, 1, 2].map(i => a[i] + (b[i] - a[i]) * t);
}

/**
 * Light modifiers for Miku, combining time of day, weather and the active scene(s).
 * Returns multipliers that the character page applies on top of its period theme.
 */
export function characterEnvironment({ hour, periodWeights, sceneWeights, weather, nowMs, sunrise, sunset }) {
  const w = normalizeWeather(weather);
  const profile = WEATHER_LIGHT[w.kind];
  const sceneEntries = Object.entries(sceneWeights || {}).filter(([, value]) => value > 0);
  let indoorWeight = 0;
  let sceneTint = [0, 0, 0];
  let rimTint = [0, 0, 0];
  let total = 0;
  for (const [id, value] of sceneEntries) {
    const light = SCENE_LIGHT[id] || SCENE_LIGHT.shibuya;
    const periodTint = [0, 1, 2].map(i => (
      light.day[i] * periodWeights.day + light.dusk[i] * periodWeights.dusk + light.night[i] * periodWeights.night
    ));
    sceneTint = sceneTint.map((c, i) => c + periodTint[i] * value);
    rimTint = rimTint.map((c, i) => c + light.rim[i] * value);
    if (light.indoor) indoorWeight += value;
    total += value;
  }
  if (total <= 0) {
    sceneTint = [1, 1, 1];
    rimTint = [0.8, 0.9, 1];
  } else {
    sceneTint = sceneTint.map(c => c / total);
    rimTint = rimTint.map(c => c / total);
    indoorWeight /= total;
  }

  // Indoors the weather only reaches through the windows.
  const weatherAmount = w.intensity * (1 - indoorWeight * 0.65);
  const blend = (key) => 1 + (profile[key] - 1) * weatherAmount;
  const weatherTint = mix3([1, 1, 1], profile.tint, weatherAmount);
  const flash = lightningFlash(nowMs, w) * (1 - indoorWeight * 0.4);

  // The sun only drives the key light during the day; at night the key comes from street / room lights.
  const sun = sunDirection(hour, sunrise, sunset);
  const night = { x: -9, y: 20, z: 18 };
  const dayish = periodWeights.day + periodWeights.dusk;
  const keyDirection = {
    x: sun.x * dayish + night.x * periodWeights.night,
    y: sun.y * dayish + night.y * periodWeights.night,
    z: sun.z * dayish + night.z * periodWeights.night
  };

  // A rim light from behind is strongest at dusk (low sun) and under neon at night.
  const rimStrength = (periodWeights.dusk * 0.9 + periodWeights.night * 0.55 + periodWeights.day * 0.25)
    * (1 - weatherAmount * 0.6);

  return {
    keyScale: blend('key'),
    ambientScale: blend('ambient'),
    fillScale: blend('fill'),
    shadowScale: blend('shadow'),
    tint: [0, 1, 2].map(i => sceneTint[i] * weatherTint[i]),
    flash,
    keyDirection,
    rimColor: rimTint,
    rimStrength,
    indoor: indoorWeight
  };
}
