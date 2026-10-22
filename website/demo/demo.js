// Runs the app's own ambience engine (ambient.js, copied unchanged from
// Wallpaper/companion) over the scene pictures, driven by the controls on the
// parent page through postMessage.
import { createAmbient } from './ambient.js';
import { timeAnchors } from './environment.js';

const SUNRISE = 6;
const SUNSET = 17.75;
const ANCHORS = timeAnchors(SUNRISE, SUNSET);

const SCENES = {
  room: ['room-day.jpg', 'room-dusk.jpg', 'room-night.jpg'],
  akihabara: ['gigo-day.jpg', 'gigo-dusk.jpg', 'gigo-night.jpg'],
  ikebukuro: ['ikebukuro-day.jpg', 'ikebukuro-dusk.jpg', 'ikebukuro-night.jpg'],
  shinjuku: ['shinjuku-day.jpg', 'shinjuku-dusk.jpg', 'shinjuku-night.jpg'],
  shibuya: ['shibuya.jpg', 'shibuya.jpg', 'shibuya.jpg'],
  hallway: ['hallway-day.jpg', 'hallway-dusk.jpg', 'hallway-night.jpg'],
  musicroom: ['musicroom-day.jpg', 'musicroom-dusk.jpg', 'musicroom-night.jpg']
};

const WEATHER = {
  clear: { kind: 'clear', intensity: 0, wind: 0.15, cloud: 0.15 },
  cloudy: { kind: 'cloudy', intensity: 0.7, wind: 0.2, cloud: 0.85 },
  fog: { kind: 'fog', intensity: 0.8, wind: 0.05, cloud: 0.8 },
  rain: { kind: 'rain', intensity: 0.75, wind: 0.3, cloud: 0.9 },
  storm: { kind: 'storm', intensity: 1, wind: 0.6, cloud: 1 },
  snow: { kind: 'snow', intensity: 0.7, wind: 0.2, cloud: 0.85 }
};

const state = { scene: 'akihabara', weather: 'rain', hour: new Date().getHours() + new Date().getMinutes() / 60, playing: false, paused: false };
const layers = { day: document.querySelector('.day'), dusk: document.querySelector('.dusk'), night: document.querySelector('.night') };
const ambient = createAmbient(document.getElementById('ambient'));
ambient.resize();
window.addEventListener('resize', () => ambient.resize());

fetch('assets/room-layout.json').then(r => r.json()).then(layout => ambient.setRoomLayout(layout)).catch(() => {});

const smooth = t => t * t * (3 - 2 * t);
function periodWeights(hour) {
  const h = ((hour % 24) + 24) % 24;
  for (let i = 0; i < ANCHORS.length - 1; i++) {
    const a = ANCHORS[i], b = ANCHORS[i + 1];
    if (h >= a.hour && h < b.hour) {
      const t = smooth((h - a.hour) / (b.hour - a.hour));
      return {
        day: a.weights.day + (b.weights.day - a.weights.day) * t,
        dusk: a.weights.dusk + (b.weights.dusk - a.weights.dusk) * t,
        night: a.weights.night + (b.weights.night - a.weights.night) * t
      };
    }
  }
  return { day: 0, dusk: 0, night: 1 };
}

function setScene(id) {
  if (!SCENES[id]) return;
  state.scene = id;
  document.body.dataset.scene = id;
  const [d, k, n] = SCENES[id];
  layers.day.style.backgroundImage = `url(assets/${d})`;
  layers.dusk.style.backgroundImage = `url(assets/${k})`;
  layers.night.style.backgroundImage = `url(assets/${n})`;
}

function report() {
  parent.postMessage({ type: 'miku-demo', hour: state.hour, playing: state.playing }, '*');
}

let lastFrame = 0;
let lastReport = 0;
function frame(now) {
  requestAnimationFrame(frame);
  if (state.paused || document.hidden) { lastFrame = now; return; }
  const dt = lastFrame ? Math.min(0.1, (now - lastFrame) / 1000) : 0;
  lastFrame = now;
  // While playing, a whole day passes in about 40 seconds.
  if (state.playing) {
    state.hour = (state.hour + dt * 0.6) % 24;
    if (now - lastReport > 120) { lastReport = now; report(); }
  }
  const w = periodWeights(state.hour);
  // Stack day, dusk and night so the visible mix matches the weights.
  layers.dusk.style.opacity = w.night >= 0.999 ? 1 : (w.dusk / (1 - w.night)).toFixed(3);
  layers.night.style.opacity = w.night.toFixed(3);
  ambient.update(now, {
    hour: state.hour,
    periodWeights: w,
    sceneWeights: { [state.scene]: 1 },
    weather: WEATHER[state.weather],
    sunrise: SUNRISE,
    sunset: SUNSET
  });
}

window.addEventListener('message', (event) => {
  const m = event.data;
  if (!m || m.type !== 'miku-demo-set') return;
  if (m.scene) setScene(m.scene);
  if (m.weather && WEATHER[m.weather]) state.weather = m.weather;
  if (typeof m.hour === 'number') state.hour = m.hour;
  if (typeof m.playing === 'boolean') state.playing = m.playing;
  if (typeof m.paused === 'boolean') state.paused = m.paused;
});

// Allow a direct link such as demo/?scene=shinjuku&weather=snow&hour=19
const q = new URLSearchParams(location.search);
setScene(q.get('scene') || state.scene);
if (WEATHER[q.get('weather')]) state.weather = q.get('weather');
if (q.has('hour')) state.hour = Number(q.get('hour')) || 0;
requestAnimationFrame(frame);
parent.postMessage({ type: 'miku-demo-ready' }, '*');
