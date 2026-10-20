import * as THREE from 'three';
import { createGrounding } from './grounding.js';

const canvas = document.querySelector('#webglCanvas');
const sceneRoot = document.querySelector('#sceneRoot');
const fallbackPortrait = document.querySelector('#fallbackPortrait');
const speechBubble = document.querySelector('#speechBubble');
const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
const hasNativeBridge = () => Boolean(window.webkit?.messageHandlers?.miku?.postMessage);
const requestedLayer = new URLSearchParams(window.location.search).get('layer');
const layerMode = ['background', 'character'].includes(requestedLayer) ? requestedLayer : 'all';
const showsBackground = layerMode !== 'character';
const showsCharacter = layerMode !== 'background';

const PERIOD_THEMES = {
  day: {
    fallback: [153, 220, 234],
    sky: 0xc8eef3,
    ground: 0x426b78,
    key: 0xfff4df,
    fill: 0xb9e4e7,
    ambientIntensity: 2.15,
    keyIntensity: 2.35,
    fillIntensity: 0.52,
    shadowOpacity: 0.18
  },
  dusk: {
    fallback: [194, 166, 214],
    sky: 0xb99bc5,
    ground: 0x453f63,
    key: 0xffc9aa,
    fill: 0xc4bce1,
    ambientIntensity: 1.92,
    keyIntensity: 2.08,
    fillIntensity: 0.46,
    shadowOpacity: 0.22
  },
  night: {
    fallback: [13, 49, 73],
    sky: 0x46677f,
    ground: 0x172a3d,
    key: 0x9de1dc,
    fill: 0x77bfc3,
    ambientIntensity: 1.52,
    keyIntensity: 1.78,
    fillIntensity: 0.40,
    shadowOpacity: 0.26
  }
};

const TIME_ANCHORS = [
  { hour: 0, weights: { day: 0, dusk: 0, night: 1 } },
  { hour: 5.5, weights: { day: 0, dusk: 0, night: 1 } },
  { hour: 8, weights: { day: 1, dusk: 0, night: 0 } },
  { hour: 15.5, weights: { day: 1, dusk: 0, night: 0 } },
  { hour: 18, weights: { day: 0, dusk: 1, night: 0 } },
  { hour: 20, weights: { day: 0, dusk: 0, night: 1 } },
  { hour: 24, weights: { day: 0, dusk: 0, night: 1 } }
];

const SCENE_CONFIGS = [
  {
    id: 'shibuya',
    day: '../assets/sekai-day.jpg',
    dusk: '../assets/sekai-dusk.jpg',
    night: '../assets/sekai-night.jpg',
    mark: '../assets/sekai-jr-overlay.svg'
  },
  {
    id: 'ikebukuro',
    day: '../assets/scenes/ikebukuro-day.jpg',
    dusk: '../assets/scenes/ikebukuro-dusk.jpg',
    night: '../assets/scenes/ikebukuro-night.jpg'
  },
  {
    id: 'akihabara',
    day: '../assets/scenes/akihabara-day.jpg',
    dusk: '../assets/scenes/akihabara-dusk.jpg',
    night: '../assets/scenes/akihabara-night.jpg'
  },
  {
    id: 'shinjuku',
    day: '../assets/scenes/shinjuku-day.jpg',
    dusk: '../assets/scenes/shinjuku-dusk.jpg',
    night: '../assets/scenes/shinjuku-night.jpg'
  },
  {
    id: 'hallway',
    day: '../assets/scenes/hallway-day.jpg',
    dusk: '../assets/scenes/hallway-dusk.jpg',
    night: '../assets/scenes/hallway-night.jpg'
  },
  {
    id: 'musicroom',
    day: '../assets/scenes/musicroom-day.jpg',
    dusk: '../assets/scenes/musicroom-dusk.jpg',
    night: '../assets/scenes/musicroom-night.jpg'
  }
];

const CAMERA_HEIGHT = 29;
const GROUND_SCREEN_Y = 0.915;
const FPS_CAP = 30;
const POSITION_ANCHORS = [0.22, 0.43, 0.62];
const CYCLE_SECONDS = 150;
const ALLOWED_EMOTIONS = new Set(['happy', 'curious', 'sleepy', 'calm']);
const ALLOWED_REPLY_ACTIONS = new Set(['wave', 'stretch', 'rest', 'idle', 'nod']);
const INTERACTION_TYPES = new Set(['headPat', 'wave', 'stretch', 'rest', 'hello', 'look', 'move']);
const CONTROLLED_BONES = [
  'センター', '上半身', '下半身', '首', '頭', '両目',
  '左肩', '左腕', '左腕捩', '左ひじ', '左手捩', '左手首',
  '右肩', '右腕', '右腕捩', '右ひじ', '右手捩', '右手首',
  '左足', '左ひざ', '左足首', '右足', '右ひざ', '右足首',
  '左ｽｶｰﾄ前', '左ｽｶｰﾄ後', '右ｽｶｰﾄ前', '右ｽｶｰﾄ後',
  '左髪１', '左髪２', '左髪３', '右髪１', '右髪２', '右髪３',
  '前髪１', '前髪２', '前髪３'
];

const state = {
  layer: layerMode,
  mode: 'fallback',
  ready: false,
  error: null,
  model: null,
  modelURL: null,
  modelName: null,
  bones: new Map(),
  restPose: new Map(),
  morphs: {},
  loadedScenes: [],
  sceneElements: new Map(),
  behavior: 'loading',
  activeScene: 'shibuya',
  currentAnchor: POSITION_ANCHORS[0],
  interactive: showsCharacter && !hasNativeBridge(),
  forcedScene: null,
  reaction: null,
  anchorHold: null,
  lookTarget: null,
  emotion: 'calm',
  bounds: null,
  lastBoundsSent: 0,
  pointer: null,
  lastLookPointerTime: 0,
  bubbleTimer: null,
  activeElapsed: 0,
  previewHour: null,
  previewElapsed: null,
  lastTimestamp: null,
  raf: null,
  renderedAt: 0
};

const smoothstep = value => {
  const bounded = THREE.MathUtils.clamp(value, 0, 1);
  return bounded * bounded * (3 - 2 * bounded);
};

const easeBetween = (value, start, end) => smoothstep((value - start) / (end - start));

function normalizeHour(hour) {
  const numericHour = Number(hour);
  if (!Number.isFinite(numericHour)) throw new TypeError('hour must be finite');
  return ((numericHour % 24) + 24) % 24;
}

function localHour() {
  const now = new Date();
  return now.getHours()
    + now.getMinutes() / 60
    + now.getSeconds() / 3600
    + now.getMilliseconds() / 3600000;
}

function periodWeightsAt(hour) {
  const normalized = normalizeHour(hour);
  let lower = TIME_ANCHORS[0];
  let upper = TIME_ANCHORS[TIME_ANCHORS.length - 1];

  for (let index = 0; index < TIME_ANCHORS.length - 1; index += 1) {
    if (normalized >= TIME_ANCHORS[index].hour && normalized < TIME_ANCHORS[index + 1].hour) {
      lower = TIME_ANCHORS[index];
      upper = TIME_ANCHORS[index + 1];
      break;
    }
  }

  const progress = (normalized - lower.hour) / (upper.hour - lower.hour);
  const eased = smoothstep(progress);
  return {
    day: THREE.MathUtils.lerp(lower.weights.day, upper.weights.day, eased),
    dusk: THREE.MathUtils.lerp(lower.weights.dusk, upper.weights.dusk, eased),
    night: THREE.MathUtils.lerp(lower.weights.night, upper.weights.night, eased)
  };
}

function mixNumber(weights, key) {
  return PERIOD_THEMES.day[key] * weights.day
    + PERIOD_THEMES.dusk[key] * weights.dusk
    + PERIOD_THEMES.night[key] * weights.night;
}

function mixRgb(weights, key) {
  return [0, 1, 2].map(index => (
    PERIOD_THEMES.day[key][index] * weights.day
    + PERIOD_THEMES.dusk[key][index] * weights.dusk
    + PERIOD_THEMES.night[key][index] * weights.night
  ));
}

function mixColor(target, weights, key) {
  const day = new THREE.Color(PERIOD_THEMES.day[key]);
  const dusk = new THREE.Color(PERIOD_THEMES.dusk[key]);
  const night = new THREE.Color(PERIOD_THEMES.night[key]);
  target.setRGB(
    day.r * weights.day + dusk.r * weights.dusk + night.r * weights.night,
    day.g * weights.day + dusk.g * weights.dusk + night.g * weights.night,
    day.b * weights.day + dusk.b * weights.dusk + night.b * weights.night,
    THREE.LinearSRGBColorSpace
  );
}

function preload(url) {
  return new Promise((resolve, reject) => {
    const image = new Image();
    image.onload = () => resolve(url);
    image.onerror = () => reject(new Error(`Missing scene asset: ${url}`));
    image.src = url;
  });
}

function createSceneElement(config) {
  if (!showsBackground) return null;
  const element = document.createElement('div');
  element.className = 'scene';
  element.dataset.scene = config.id;

  for (const period of ['day', 'dusk', 'night']) {
    const layer = document.createElement('div');
    layer.className = `scene-layer scene-${period}`;
    layer.style.backgroundImage = `url('${config[period]}')`;
    element.append(layer);
  }

  if (config.mark) {
    const mark = document.createElement('div');
    mark.className = 'scene-mark';
    mark.style.backgroundImage = `url('${config.mark}')`;
    element.append(mark);
  }

  sceneRoot.append(element);
  state.sceneElements.set(config.id, element);
  return element;
}

async function prepareScenes() {
  for (const config of SCENE_CONFIGS) createSceneElement(config);

  const results = await Promise.all(SCENE_CONFIGS.map(async config => {
    try {
      await Promise.all(['day', 'dusk', 'night'].map(period => preload(config[period])));
      return config.id;
    } catch {
      state.sceneElements.get(config.id).remove();
      state.sceneElements.delete(config.id);
      return null;
    }
  }));

  state.loadedScenes = results.filter(Boolean);
  if (state.loadedScenes.length === 0) state.loadedScenes = ['shibuya'];
}

function sceneWeightsAt(elapsed) {
  const ids = state.loadedScenes;
  if (state.forcedScene && ids.includes(state.forcedScene)) return { [state.forcedScene]: 1 };
  if (ids.length <= 1 || reducedMotion.matches) return { [ids[0] || 'shibuya']: 1 };

  const slot = 90;
  const fadeStart = 82;
  const cycle = slot * ids.length;
  const time = ((elapsed % cycle) + cycle) % cycle;
  const index = Math.floor(time / slot);
  const within = time - index * slot;
  const next = (index + 1) % ids.length;
  const fade = within <= fadeStart ? 0 : smoothstep((within - fadeStart) / (slot - fadeStart));

  return {
    [ids[index]]: 1 - fade,
    [ids[next]]: fade
  };
}

function sourceOverOpacities(weights, orderedIds) {
  const opacities = {};
  let cumulativeWeight = 0;

  for (const id of orderedIds) {
    const weight = weights[id] || 0;
    cumulativeWeight += weight;
    opacities[id] = cumulativeWeight > 0 ? weight / cumulativeWeight : 0;
  }

  return opacities;
}

function applyBackground(hour, elapsed) {
  const weights = periodWeightsAt(hour);
  if (!showsBackground) {
    const sceneWeights = sceneWeightsAt(elapsed);
    state.activeScene = Object.entries(sceneWeights).sort((left, right) => right[1] - left[1])[0]?.[0] || 'shibuya';
    return { periodWeights: weights, sceneWeights };
  }
  const visibleUnderNight = weights.day + weights.dusk;
  const duskOpacity = visibleUnderNight > 0 ? weights.dusk / visibleUnderNight : 0;
  const sceneWeights = sceneWeightsAt(elapsed);
  const sceneOpacities = sourceOverOpacities(sceneWeights, [...state.sceneElements.keys()]);
  const fallback = mixRgb(weights, 'fallback').map(Math.round);
  document.documentElement.style.setProperty('--scene-fallback', `rgb(${fallback.join(' ')})`);

  for (const [id, element] of state.sceneElements) {
    element.style.opacity = String(sceneOpacities[id] || 0);
    element.querySelector('.scene-dusk').style.opacity = String(duskOpacity);
    element.querySelector('.scene-night').style.opacity = String(weights.night);
  }

  state.activeScene = Object.entries(sceneWeights).sort((left, right) => right[1] - left[1])[0]?.[0] || 'shibuya';
  return { periodWeights: weights, sceneWeights };
}

function postNative(message) {
  const handler = window.webkit?.messageHandlers?.miku;
  if (!handler?.postMessage) return false;
  handler.postMessage(message);
  return true;
}

function showBubble(text, emotion = 'calm', duration = 5200) {
  if (!showsCharacter) return;
  const safeText = typeof text === 'string' ? text.trim().slice(0, 240) : '';
  if (!safeText) return;
  const safeEmotion = ALLOWED_EMOTIONS.has(emotion) ? emotion : 'calm';
  speechBubble.textContent = safeText;
  speechBubble.dataset.emotion = safeEmotion;
  speechBubble.classList.add('visible');
  clearTimeout(state.bubbleTimer);
  state.bubbleTimer = window.setTimeout(() => speechBubble.classList.remove('visible'), duration);
}

function holdAnchor(anchor, elapsed, seconds = 12) {
  state.anchorHold = {
    anchor: THREE.MathUtils.clamp(anchor, 0.16, 0.68),
    until: elapsed + seconds,
    releaseEnd: elapsed + seconds + 4
  };
}

function startReaction(type, options = {}) {
  if (!INTERACTION_TYPES.has(type)) return false;
  const elapsed = currentElapsed();
  const durations = {
    headPat: 2.8,
    wave: 4.8,
    stretch: 5.2,
    rest: 5.5,
    hello: 3.2,
    look: 2.4,
    move: 4.2
  };
  const targetAnchor = Number.isFinite(Number(options.x))
    ? THREE.MathUtils.clamp(Number(options.x), 0.16, 0.68)
    : state.currentAnchor;
  const distance = Math.abs(targetAnchor - state.currentAnchor);
  const duration = type === 'move'
    ? THREE.MathUtils.clamp(2.8 + distance * 10, 2.8, 6.2)
    : durations[type];

  state.reaction = {
    type,
    start: elapsed,
    end: elapsed + duration,
    duration,
    fromAnchor: state.currentAnchor,
    toAnchor: targetAnchor
  };
  holdAnchor(type === 'move' ? targetAnchor : state.currentAnchor, elapsed, duration + 8);

  if ((type === 'look' || type === 'headPat') && Number.isFinite(Number(options.x))) {
    state.lookTarget = {
      x: THREE.MathUtils.clamp(Number(options.x), 0, 1),
      y: THREE.MathUtils.clamp(Number(options.y ?? 0.35), 0, 1),
      until: elapsed + duration
    };
  }
  return true;
}

function activeReactionAt(elapsed) {
  const reaction = state.reaction;
  if (!reaction) return null;
  if (elapsed > reaction.end) {
    state.reaction = null;
    return null;
  }
  return {
    ...reaction,
    progress: THREE.MathUtils.clamp((elapsed - reaction.start) / reaction.duration, 0, 1)
  };
}

function heldAnchorAt(routineAnchor, elapsed) {
  const hold = state.anchorHold;
  if (!hold) return routineAnchor;
  if (elapsed <= hold.until) return hold.anchor;
  if (elapsed < hold.releaseEnd) {
    const release = smoothstep((elapsed - hold.until) / (hold.releaseEnd - hold.until));
    return THREE.MathUtils.lerp(hold.anchor, routineAnchor, release);
  }
  state.anchorHold = null;
  return routineAnchor;
}

let renderer;
let scene;
let camera;
let hemisphereLight;
let directionalLight;
let fillLight;
let grounding;
const raycaster = new THREE.Raycaster();
const pointerNdc = new THREE.Vector2();
const modelBox = new THREE.Box3();
const projectedPoint = new THREE.Vector3();

function setupRenderer() {
  renderer = new THREE.WebGLRenderer({
    canvas,
    alpha: true,
    antialias: true,
    powerPreference: 'low-power'
  });
  renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 1.5));
  renderer.setSize(window.innerWidth, window.innerHeight, false);
  renderer.setClearColor(0x000000, 0);
  renderer.outputColorSpace = THREE.SRGBColorSpace;

  scene = new THREE.Scene();
  camera = new THREE.OrthographicCamera();
  camera.position.set(0, 10.5, 30);
  camera.lookAt(0, 10.5, 0);

  hemisphereLight = new THREE.HemisphereLight(0xc8eef3, 0x426b78, 2.15);
  scene.add(hemisphereLight);

  directionalLight = new THREE.DirectionalLight(0xfff4df, 2.35);
  directionalLight.position.set(-10, 22, 18);
  scene.add(directionalLight);

  fillLight = new THREE.DirectionalLight(0xb9e4e7, 0.52);
  fillLight.position.set(11, 14, 10);
  fillLight.castShadow = false;
  scene.add(fillLight);

  grounding = createGrounding(scene);

  resize();
}

function resize() {
  if (!renderer || !camera) return;
  const width = Math.max(1, window.innerWidth);
  const height = Math.max(1, window.innerHeight);
  const halfHeight = CAMERA_HEIGHT / 2;
  const halfWidth = halfHeight * width / height;
  camera.left = -halfWidth;
  camera.right = halfWidth;
  camera.top = halfHeight;
  camera.bottom = -halfHeight;
  camera.near = 0.1;
  camera.far = 100;
  camera.updateProjectionMatrix();
  renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 1.5));
  renderer.setSize(width, height, false);
}

function screenAnchorToWorld(anchor) {
  return THREE.MathUtils.lerp(camera.left, camera.right, anchor);
}

function updateCharacterBounds(timestamp) {
  if (!state.model || !camera) return;
  if (timestamp - state.lastBoundsSent < 100) return;
  state.lastBoundsSent = timestamp;
  modelBox.setFromObject(state.model);
  if (modelBox.isEmpty()) return;

  let minX = 1;
  let minY = 1;
  let maxX = 0;
  let maxY = 0;
  for (const x of [modelBox.min.x, modelBox.max.x]) {
    for (const y of [modelBox.min.y, modelBox.max.y]) {
      for (const z of [modelBox.min.z, modelBox.max.z]) {
        projectedPoint.set(x, y, z).project(camera);
        minX = Math.min(minX, (projectedPoint.x + 1) / 2);
        maxX = Math.max(maxX, (projectedPoint.x + 1) / 2);
        minY = Math.min(minY, (1 - projectedPoint.y) / 2);
        maxY = Math.max(maxY, (1 - projectedPoint.y) / 2);
      }
    }
  }

  const rawWidth = maxX - minX;
  const rawHeight = maxY - minY;
  const rect = {
    x: THREE.MathUtils.clamp(minX + rawWidth * 0.035, 0, 1),
    y: THREE.MathUtils.clamp(minY + rawHeight * 0.01, 0, 1),
    width: THREE.MathUtils.clamp(rawWidth * 0.93, 0.01, 1),
    height: THREE.MathUtils.clamp(rawHeight * 0.98, 0.01, 1)
  };
  rect.width = Math.min(rect.width, 1 - rect.x);
  rect.height = Math.min(rect.height, 1 - rect.y);
  state.bounds = rect;

  speechBubble.style.left = `${THREE.MathUtils.clamp(rect.x + rect.width * 0.5, 0.15, 0.85) * 100}%`;
  speechBubble.style.top = `${Math.max(0.025, rect.y - 0.045) * 100}%`;
  postNative({ type: 'bounds', rect: { ...rect } });
}

function raycastCharacter(clientX, clientY) {
  if (!state.model || !state.interactive) return null;
  const rect = canvas.getBoundingClientRect();
  pointerNdc.set(
    ((clientX - rect.left) / rect.width) * 2 - 1,
    -((clientY - rect.top) / rect.height) * 2 + 1
  );
  raycaster.setFromCamera(pointerNdc, camera);
  const hit = raycaster.intersectObject(state.model, true)[0];
  if (!hit) return null;

  modelBox.setFromObject(state.model);
  const height = Math.max(0.001, modelBox.max.y - modelBox.min.y);
  const width = Math.max(0.001, modelBox.max.x - modelBox.min.x);
  const normalizedHeight = (hit.point.y - modelBox.min.y) / height;
  const lateral = Math.abs((hit.point.x - (modelBox.min.x + modelBox.max.x) / 2) / width);
  let zone = 'none';
  if (normalizedHeight >= 0.73) zone = 'head';
  else if (normalizedHeight >= 0.43 && lateral >= 0.19) zone = 'hand';
  else if (normalizedHeight >= 0.4) zone = 'torso';
  return { hit, zone, normalizedHeight, lateral };
}

const euler = new THREE.Euler();
const quaternion = new THREE.Quaternion();

function resetSkeleton() {
  for (const [bone, rest] of state.restPose) {
    bone.position.copy(rest.position);
    bone.quaternion.copy(rest.quaternion);
    bone.scale.copy(rest.scale);
  }
}

function rotateBone(name, x = 0, y = 0, z = 0, weight = 1) {
  const bone = state.bones.get(name);
  if (!bone || weight === 0) return;
  euler.set(x * weight, y * weight, z * weight, 'XYZ');
  quaternion.setFromEuler(euler);
  bone.quaternion.multiply(quaternion);
}

function offsetBone(name, x = 0, y = 0, z = 0, weight = 1) {
  const bone = state.bones.get(name);
  if (!bone || weight === 0) return;
  bone.position.x += x * weight;
  bone.position.y += y * weight;
  bone.position.z += z * weight;
}

function setMorph(name, value) {
  const index = state.morphs[name];
  if (index === undefined || !state.model?.morphTargetInfluences) return;
  state.model.morphTargetInfluences[index] = THREE.MathUtils.clamp(value, 0, 1);
}

function setSmile(value) {
  if (state.morphs['口角上げ'] === undefined) {
    setMorph('にこり', value);
    return;
  }
  setMorph('にこり', Math.min(0.12, value * 0.16));
  setMorph('口角上げ', Math.min(0.55, 0.12 + value * 0.4));
  setMorph('にっこり', Math.min(0.22, Math.max(0, value - 0.2) * 0.4));
}

function normalizeEyeMorphs() {
  const influences = state.model?.morphTargetInfluences;
  if (!influences) return;
  const blink = influences[state.morphs['まばたき']] || 0;
  const styles = ['なごみ', '笑い'].map(name => state.morphs[name]).filter(index => index !== undefined);
  const total = styles.reduce((sum, index) => sum + influences[index], 0);
  const remaining = Math.max(0, 1 - blink);
  if (total > remaining) {
    for (const index of styles) influences[index] *= remaining / total;
  }
}

function resetMorphs() {
  if (!state.model?.morphTargetInfluences) return;
  state.model.morphTargetInfluences.fill(0);
}

function gestureEnvelope(progress) {
  return easeBetween(progress, 0, 0.18) * (1 - easeBetween(progress, 0.82, 1));
}

function blinkAmount(elapsed) {
  const cycle = elapsed % 5.7;
  const pulse = (center, width) => {
    const distance = Math.abs(cycle - center);
    return distance >= width ? 0 : Math.cos(distance / width * Math.PI / 2);
  };
  return Math.max(pulse(4.62, 0.115), pulse(4.94, 0.095) * 0.48);
}

function behaviorAt(elapsed) {
  const time = ((elapsed % CYCLE_SECONDS) + CYCLE_SECONDS) % CYCLE_SECONDS;
  const segment = (name, start, end, from = null, to = null) => ({
    name,
    progress: THREE.MathUtils.clamp((time - start) / (end - start), 0, 1),
    from,
    to
  });

  if (time >= 15 && time < 22) return segment('wave', 15, 22);
  if (time >= 38 && time < 46) return segment('stretch', 38, 46);
  if (time >= 58 && time < 68) return segment('walk', 58, 68, 0, 1);
  if (time >= 84 && time < 96) return segment('rest-standing', 84, 96);
  if (time >= 112 && time < 122) return segment('walk', 112, 122, 1, 2);
  if (time >= 125 && time < 132) return segment('wave', 125, 132);
  if (time >= 138 && time < 150) return segment('walk', 138, 150, 2, 0);
  return segment('idle', 0, 1);
}

function anchorAt(elapsed, behavior) {
  const time = ((elapsed % CYCLE_SECONDS) + CYCLE_SECONDS) % CYCLE_SECONDS;
  if (behavior.name === 'walk') {
    const from = POSITION_ANCHORS[behavior.from];
    const to = POSITION_ANCHORS[behavior.to];
    return THREE.MathUtils.lerp(from, to, smoothstep(behavior.progress));
  }
  if (time < 58) return POSITION_ANCHORS[0];
  if (time < 112) return POSITION_ANCHORS[1];
  if (time < 138) return POSITION_ANCHORS[2];
  return POSITION_ANCHORS[2];
}

const facePosition = new THREE.Vector3();
const otherEyePosition = new THREE.Vector3();

function projectedFaceAnchor() {
  if (!camera) return null;
  const leftEye = state.bones.get('左目');
  const rightEye = state.bones.get('右目');
  const head = state.bones.get('頭');
  if (leftEye && rightEye) {
    leftEye.getWorldPosition(facePosition);
    rightEye.getWorldPosition(otherEyePosition);
    facePosition.add(otherEyePosition).multiplyScalar(0.5);
  } else if (head) {
    head.getWorldPosition(facePosition);
  } else {
    return null;
  }
  facePosition.project(camera);
  if (!Number.isFinite(facePosition.x) || !Number.isFinite(facePosition.y)) return null;
  return {
    x: THREE.MathUtils.clamp((facePosition.x + 1) / 2, 0, 1),
    y: THREE.MathUtils.clamp((1 - facePosition.y) / 2, 0, 1)
  };
}

function applyBasePose(elapsed) {
  const breath = Math.sin(elapsed * Math.PI * 2 / 5.8);
  const gaze = Math.sin(elapsed * 0.31);
  const trackedLook = state.lookTarget && elapsed <= state.lookTarget.until
    ? state.lookTarget
    : null;
  const faceAnchor = trackedLook ? projectedFaceAnchor() : null;
  const lookX = faceAnchor ? THREE.MathUtils.clamp((trackedLook.x - faceAnchor.x) * 0.24, -0.12, 0.12) : 0;
  const lookY = faceAnchor ? THREE.MathUtils.clamp((trackedLook.y - faceAnchor.y) * 0.16, -0.08, 0.08) : 0;
  offsetBone('センター', 0, 0.035 * breath, 0);
  rotateBone('上半身', 0.018 * breath, 0, 0.018 * Math.sin(elapsed * 0.42));
  rotateBone('首', 0.018 + lookY * 0.25, 0.035 * gaze + lookX * 0.25, -0.018 * gaze);
  rotateBone('頭', -0.015 + lookY * 0.4, 0.045 * gaze + lookX * 0.42, 0.035 * Math.sin(elapsed * 0.23));
  rotateBone('両目', 0.006 * Math.sin(elapsed * 0.37) + lookY, 0.025 * gaze + lookX, 0);

  rotateBone('左腕', 0.03, 0, -0.50);
  rotateBone('右腕', -0.03, 0, 0.50);
  rotateBone('左ひじ', 0.04, 0.02, 0.12);
  rotateBone('右ひじ', -0.04, -0.02, -0.12);
  rotateBone('左手首', 0.03, 0, -0.06);
  rotateBone('右手首', -0.03, 0, 0.06);

  const sway = Math.sin(elapsed * 0.72) * 0.018;
  ['左髪１', '左髪２', '左髪３'].forEach((name, index) => {
    rotateBone(name, 0.012 + index * 0.006, 0, sway * (1 + index * 0.28));
  });
  ['右髪１', '右髪２', '右髪３'].forEach((name, index) => {
    rotateBone(name, 0.012 + index * 0.006, 0, -sway * (1 + index * 0.28));
  });
  rotateBone('前髪１', 0.008 * breath, 0, 0.006 * gaze);
  rotateBone('前髪２', 0.009 * breath, 0, 0);
  rotateBone('前髪３', 0.008 * breath, 0, -0.006 * gaze);

  setMorph('まばたき', blinkAmount(elapsed));
  setSmile(0.12 + 0.04 * Math.sin(elapsed * 0.29));
  if (state.emotion === 'happy') setSmile(0.32);
  if (state.emotion === 'sleepy') setMorph('まばたき', Math.max(blinkAmount(elapsed), 0.18));
  if (state.emotion === 'curious') rotateBone('頭', 0, 0.035, 0.045);
}

function applyWave(progress, elapsed) {
  const weight = gestureEnvelope(progress);
  const wave = Math.sin(progress * Math.PI * 9);
  rotateBone('左肩', 0, 0, 0.16, weight);
  rotateBone('左腕', -0.08, -0.1, 1.05, weight);
  rotateBone('左ひじ', 0.06, -0.06, 1.34 + 0.08 * wave, weight);
  rotateBone('左手首', 0.04, 0.1 * wave, 0.22 * wave, weight);
  rotateBone('頭', 0, -0.08, -0.09, weight);
  setSmile(Math.max(0.12, 0.67 * weight));
  setMorph('ω', 0.16 * weight);
  setMorph('笑い', 0.08 * weight * Math.max(0, Math.sin(elapsed * 1.7)));
}

function applyStretch(progress) {
  const weight = gestureEnvelope(progress);
  const rise = Math.sin(Math.PI * progress);
  offsetBone('センター', 0, 0.24 * rise, 0, weight);
  rotateBone('上半身', -0.12, 0, 0, weight);
  rotateBone('首', 0.08, 0, 0, weight);
  rotateBone('頭', 0.06, 0, 0, weight);
  rotateBone('左肩', 0, 0, 0.12, weight);
  rotateBone('右肩', 0, 0, -0.12, weight);
  rotateBone('左腕', 0.08, 0, 1.87, weight);
  rotateBone('右腕', -0.08, 0, -1.87, weight);
  rotateBone('左ひじ', 0, 0, 0.02, weight);
  rotateBone('右ひじ', 0, 0, -0.02, weight);
  rotateBone('左手首', 0, 0, 0.1, weight);
  rotateBone('右手首', 0, 0, -0.1, weight);
  setMorph('なごみ', 0.28 * weight);
}

function applySkirtFollow(leftSwing, rightSwing, weight = 1) {
  if (state.bones.has('スカート_0_0')) {
    for (let index = 0; index < 8; index += 1) {
      const angle = index * Math.PI / 4;
      const front = Math.cos(angle);
      const leftWeight = (1 + Math.sin(angle)) / 2;
      const rightWeight = 1 - leftWeight;
      const forward = Math.max(0, -leftSwing) * leftWeight + Math.max(0, -rightSwing) * rightWeight;
      const backward = Math.max(0, leftSwing) * leftWeight + Math.max(0, rightSwing) * rightWeight;
      const opening = (Math.max(0, front) * forward + Math.max(0, -front) * backward) * 0.5;
      rotateBone(`スカート_0_${index}`, -front * opening, 0, Math.sin(angle) * opening, weight);
    }
    return;
  }
  rotateBone('左ｽｶｰﾄ前', Math.min(0, leftSwing) * 0.9, 0, 0, weight);
  rotateBone('左ｽｶｰﾄ後', Math.max(0, leftSwing) * 0.9, 0, 0, weight);
  rotateBone('右ｽｶｰﾄ前', Math.min(0, rightSwing) * 0.9, 0, 0, weight);
  rotateBone('右ｽｶｰﾄ後', Math.max(0, rightSwing) * 0.9, 0, 0, weight);
}

function applyRest(progress) {
  const weight = gestureEnvelope(progress);
  rotateBone('上半身', 0.04, 0, -0.035, weight);
  rotateBone('下半身', 0, 0, 0.045, weight);
  rotateBone('首', 0.025, 0, 0.075, weight);
  rotateBone('頭', -0.025, 0, 0.09, weight);
  offsetBone('センター', 0.18, -0.07, 0, weight);
  rotateBone('左足', -0.05, 0, 0.035, weight);
  rotateBone('左ひざ', 0.13, 0, 0, weight);
  rotateBone('左足首', -0.08, 0, 0, weight);
  applySkirtFollow(-0.05, 0, weight);
  rotateBone('左腕', 0.25, 0.08, 0.12, weight);
  rotateBone('右腕', 0.25, -0.08, -0.12, weight);
  rotateBone('左ひじ', -0.58, 0.04, 0.10, weight);
  rotateBone('右ひじ', -0.58, -0.04, -0.10, weight);
  rotateBone('左手首', 0.08, 0.08, 0.08, weight);
  rotateBone('右手首', 0.08, -0.08, -0.08, weight);
  setMorph('まばたき', Math.max(blinkAmount(state.previewElapsed ?? state.activeElapsed), 0.82 * weight));
  setMorph('なごみ', 0.52 * weight);
}

function applyHeadPat(progress) {
  const weight = gestureEnvelope(progress);
  const nuzzle = Math.sin(progress * Math.PI * 3) * weight;
  rotateBone('首', 0.035, -0.025, 0.1, weight);
  rotateBone('頭', 0.05 + 0.025 * nuzzle, -0.04, 0.12, weight);
  rotateBone('左髪１', 0.025, 0, 0.035 * nuzzle, weight);
  rotateBone('右髪１', 0.025, 0, -0.035 * nuzzle, weight);
  setMorph('まばたき', Math.max(blinkAmount(state.previewElapsed ?? state.activeElapsed), 0.72 * weight));
  setSmile(Math.max(0.12, 0.74 * weight));
  setMorph('ω', 0.12 * weight);
}

function applyNod(progress, curious = false) {
  const weight = gestureEnvelope(progress);
  const nod = Math.sin(progress * Math.PI * 4) * weight;
  rotateBone('首', 0.07 * nod, curious ? 0.06 * weight : 0, 0.025 * weight);
  rotateBone('頭', 0.13 * nod, curious ? 0.1 * weight : 0, 0.045 * weight);
  setSmile(Math.max(0.12, 0.46 * weight));
}

function applyWalk(behavior, elapsed) {
  const weight = gestureEnvelope(behavior.progress);
  const stride = Math.sin(behavior.progress * Math.PI * 8);
  const fromAnchor = behavior.fromAnchor ?? POSITION_ANCHORS[behavior.from];
  const toAnchor = behavior.toAnchor ?? POSITION_ANCHORS[behavior.to];
  const direction = Math.sign(toAnchor - fromAnchor) || 1;
  const turnIn = easeBetween(behavior.progress, 0, 0.14);
  const turnOut = 1 - easeBetween(behavior.progress, 0.84, 1);
  state.model.rotation.y = direction * 1.22 * turnIn * turnOut;
  offsetBone('センター', 0, Math.abs(stride) * 0.06 * weight, 0);
  rotateBone('上半身', 0.025, -0.05 * stride, 0, weight);
  rotateBone('左足', 0.20 * stride, 0, 0, weight);
  rotateBone('右足', -0.20 * stride, 0, 0, weight);
  rotateBone('左ひざ', Math.max(0, -stride) * 0.30, 0, 0, weight);
  rotateBone('右ひざ', Math.max(0, stride) * 0.30, 0, 0, weight);
  rotateBone('左足首', -0.08 * stride, 0, 0, weight);
  rotateBone('右足首', 0.08 * stride, 0, 0, weight);
  // The skirt has no physics, so each panel follows the thigh moving towards it.
  applySkirtFollow(0.20 * stride, -0.20 * stride, weight);
  rotateBone('左腕', -0.16 * stride, 0, 0, weight);
  rotateBone('右腕', 0.16 * stride, 0, 0, weight);
  rotateBone('左髪１', 0.035, -0.08 * stride, 0, weight);
  rotateBone('右髪１', 0.035, -0.08 * stride, 0, weight);
}

const grantRotation = new THREE.Quaternion();
const identityRotation = new THREE.Quaternion();

function applyGrantRotations() {
  const bones = state.model.skeleton?.bones || [];
  const grants = state.model.geometry?.userData?.MMD?.grants || [];
  for (const grant of grants) {
    if (grant.isLocal || !grant.affectRotation) continue;
    const bone = bones[grant.index];
    const source = bones[grant.parentIndex];
    const rest = state.restPose.get(source);
    if (!bone || !source || !rest) continue;
    quaternion.copy(rest.quaternion).invert().multiply(source.quaternion);
    grantRotation.slerpQuaternions(identityRotation, quaternion, grant.ratio);
    bone.quaternion.multiply(grantRotation);
  }
}

function applyHairClearance() {
  let pitch = 0;
  let roll = 0;
  for (const name of ['上半身', '上半身2', '首', '頭']) {
    const bone = state.bones.get(name);
    const rest = state.restPose.get(bone);
    if (!bone || !rest) continue;
    quaternion.copy(rest.quaternion).invert().multiply(bone.quaternion);
    euler.setFromQuaternion(quaternion, 'XYZ');
    pitch += euler.x;
    roll += euler.z;
  }
  // Long tails hang behind the body instead of swinging through it when the head tilts.
  const bias = state.bones.has('腰パーツ親') ? 0 : 0.04;
  const counterPitch = THREE.MathUtils.clamp(Math.max(0, -pitch) + bias, 0, 0.25);
  const counterRoll = THREE.MathUtils.clamp(-roll * 0.8, -0.20, 0.20);
  rotateBone('左髪１', counterPitch, 0, counterRoll);
  rotateBone('右髪１', counterPitch, 0, counterRoll);
}

function updateModel(elapsed) {
  if (!state.model) return;
  resetSkeleton();
  resetMorphs();
  state.model.rotation.y = 0;

  const routineBehavior = behaviorAt(elapsed);
  const routineAnchor = anchorAt(elapsed, routineBehavior);
  const pointerReaction = state.pointer?.dragging
    ? { type: 'drag', progress: 0.5, fromAnchor: state.currentAnchor, toAnchor: state.currentAnchor }
    : null;
  const reaction = reducedMotion.matches ? null : pointerReaction || activeReactionAt(elapsed);
  const behavior = reaction || (reducedMotion.matches ? { name: 'idle', progress: 0 } : routineBehavior);
  let anchor = reducedMotion.matches ? POSITION_ANCHORS[1] : heldAnchorAt(routineAnchor, elapsed);
  if (reaction?.type === 'move') {
    anchor = THREE.MathUtils.lerp(reaction.fromAnchor, reaction.toAnchor, smoothstep(reaction.progress));
  }
  state.model.position.x = screenAnchorToWorld(anchor);
  state.currentAnchor = anchor;
  state.behavior = reducedMotion.matches
    ? 'idle-reduced'
    : reaction ? `interactive-${reaction.type}` : behavior.name;

  if (!reducedMotion.matches) applyBasePose(elapsed);
  else {
    rotateBone('左腕', 0.03, 0, -0.50);
    rotateBone('右腕', -0.03, 0, 0.50);
    rotateBone('左ひじ', 0.04, 0.02, 0.12);
    rotateBone('右ひじ', -0.04, -0.02, -0.12);
    setSmile(0.12);
  }

  const behaviorName = reaction?.type || behavior.name;
  if (behaviorName === 'wave') applyWave(behavior.progress, elapsed);
  if (behaviorName === 'stretch') applyStretch(behavior.progress);
  if (behaviorName === 'rest-standing' || behaviorName === 'rest') applyRest(behavior.progress);
  if (behaviorName === 'walk' || behaviorName === 'move') applyWalk(behavior, elapsed);
  if (behaviorName === 'headPat') applyHeadPat(behavior.progress);
  if (behaviorName === 'hello') applyNod(behavior.progress, true);

  normalizeEyeMorphs();
  applyGrantRotations();
  applyHairClearance();
  state.model.updateMatrixWorld(true);
}

function applyLighting(weights) {
  const intensityScale = state.model?.geometry.userData.MMD?.format === 'pmx' ? 0.65 : 1;
  mixColor(hemisphereLight.color, weights, 'sky');
  mixColor(hemisphereLight.groundColor, weights, 'ground');
  mixColor(directionalLight.color, weights, 'key');
  mixColor(fillLight.color, weights, 'fill');
  hemisphereLight.intensity = mixNumber(weights, 'ambientIntensity') * intensityScale;
  directionalLight.intensity = mixNumber(weights, 'keyIntensity') * intensityScale;
  fillLight.intensity = mixNumber(weights, 'fillIntensity') * intensityScale;
}

async function loadModel() {
  try {
    const { loadCompanionModel } = await import('./model-loader.js');
    const { model, url, name } = await loadCompanionModel();
    state.model = model;
    state.modelURL = url;
    state.modelName = name;
    state.model.scale.setScalar(0.93);
    state.model.position.set(screenAnchorToWorld(POSITION_ANCHORS[0]), 0, 0);
    state.model.castShadow = true;
    state.model.receiveShadow = false;
    state.model.frustumCulled = false;
    state.model.traverse(object => {
      if (object.isMesh) {
        object.castShadow = true;
        object.frustumCulled = false;
      }
    });
    scene.add(state.model);
    grounding.attach(state.model);

    for (const bone of state.model.skeleton?.bones || []) {
      state.bones.set(bone.name, bone);
      state.restPose.set(bone, {
        position: bone.position.clone(),
        quaternion: bone.quaternion.clone(),
        scale: bone.scale.clone()
      });
    }
    state.morphs = { ...(state.model.morphTargetDictionary || {}) };
    state.ready = true;
    state.mode = 'webgl-mmd';
    document.body.classList.add('webgl-ready');
    renderState(performance.now());
  } catch (error) {
    state.error = error?.message || String(error);
    state.mode = 'fallback';
  }
}

function currentElapsed() {
  return state.previewElapsed ?? state.activeElapsed;
}

function currentHour() {
  return state.previewHour ?? localHour();
}

function renderState(timestamp) {
  const elapsed = currentElapsed();
  const hour = currentHour();
  const background = applyBackground(hour, elapsed);
  if (showsCharacter && state.ready) {
    applyLighting(background.periodWeights);
    updateModel(elapsed);
    grounding.update(
      camera.position.y + CAMERA_HEIGHT * (0.5 - GROUND_SCREEN_Y),
      mixNumber(background.periodWeights, 'shadowOpacity') * 1.5
    );
    renderer.render(scene, camera);
    updateCharacterBounds(timestamp);
  }
  state.renderedAt = timestamp;
}

function frame(timestamp) {
  const interval = reducedMotion.matches ? 1000 : 1000 / FPS_CAP;
  if (state.lastTimestamp === null) state.lastTimestamp = timestamp;
  const delta = Math.min((timestamp - state.lastTimestamp) / 1000, 0.1);
  state.lastTimestamp = timestamp;
  if (state.previewElapsed === null) state.activeElapsed += delta;

  if (timestamp - state.renderedAt >= interval) renderState(timestamp);
  state.raf = requestAnimationFrame(frame);
}

function startLoop() {
  if (state.raf !== null || document.hidden) return;
  state.lastTimestamp = null;
  state.raf = requestAnimationFrame(frame);
}

function stopLoop() {
  if (state.raf !== null) cancelAnimationFrame(state.raf);
  state.raf = null;
  state.lastTimestamp = null;
}

function normalizedPointer(event) {
  const rect = canvas.getBoundingClientRect();
  return {
    x: THREE.MathUtils.clamp((event.clientX - rect.left) / rect.width, 0, 1),
    y: THREE.MathUtils.clamp((event.clientY - rect.top) / rect.height, 0, 1)
  };
}

function browserReactionText(zone) {
  if (zone === 'head') return ['嘿嘿♪', '今天也一起加油呀。'];
  if (zone === 'hand') return ['嗨～', '見到你真好！'];
  return ['你好呀！', '想和我聊聊嗎？'];
}

function handlePointerDown(event) {
  if (!showsCharacter || !state.interactive || event.button !== 0) return;
  const result = raycastCharacter(event.clientX, event.clientY);
  if (!result || result.zone === 'none') return;
  const point = normalizedPointer(event);
  state.pointer = {
    id: event.pointerId,
    startX: event.clientX,
    startY: event.clientY,
    zone: result.zone,
    dragging: false
  };
  canvas.setPointerCapture?.(event.pointerId);
  postNative({ type: 'haptic' });

  if (result.zone === 'head') startReaction('headPat', point);
  else if (result.zone === 'hand') startReaction('wave', point);
  else startReaction('hello', point);

  if (!hasNativeBridge()) {
    const [text, alternate] = browserReactionText(result.zone);
    showBubble(Math.random() > 0.5 ? text : alternate, result.zone === 'head' ? 'happy' : 'curious', 2600);
  }
}

function handlePointerMove(event) {
  if (!state.interactive) return;
  const point = normalizedPointer(event);
  const elapsed = currentElapsed();
  if (state.pointer?.id === event.pointerId) {
    const distance = Math.hypot(event.clientX - state.pointer.startX, event.clientY - state.pointer.startY);
    if (distance > 7) {
      state.pointer.dragging = true;
      state.reaction = null;
      holdAnchor(point.x, elapsed, 15);
    }
  }

  const now = performance.now();
  if (now - state.lastLookPointerTime < 50) return;
  state.lastLookPointerTime = now;
  const bounds = state.bounds;
  if (bounds
    && point.x >= bounds.x && point.x <= bounds.x + bounds.width
    && point.y >= bounds.y && point.y <= bounds.y + bounds.height) {
    state.lookTarget = { x: point.x, y: point.y, until: elapsed + 0.8 };
  }
}

function finishPointer(event) {
  const pointer = state.pointer;
  if (!pointer || pointer.id !== event.pointerId) return;
  canvas.releasePointerCapture?.(event.pointerId);
  state.pointer = null;
}

canvas.addEventListener('pointerdown', handlePointerDown);
canvas.addEventListener('pointermove', handlePointerMove, { passive: true });
canvas.addEventListener('pointerup', event => finishPointer(event));
canvas.addEventListener('pointercancel', event => finishPointer(event));

function status() {
  const elapsed = currentElapsed();
  const hour = currentHour();
  const behavior = state.ready
    ? state.behavior
    : showsCharacter
      ? reducedMotion.matches ? 'idle-reduced' : behaviorAt(elapsed).name
      : 'background';
  const requiredBones = Object.fromEntries(CONTROLLED_BONES.map(name => [name, state.bones.has(name)]));
  return {
    layer: layerMode,
    ready: state.ready,
    mode: state.mode,
    error: state.error,
    renderer: showsCharacter ? 'Three.js r171 MMDLoader' : null,
    model: showsCharacter ? state.modelURL : null,
    modelName: showsCharacter ? state.modelName : null,
    fpsCap: FPS_CAP,
    dpr: Math.min(window.devicePixelRatio || 1, 1.5),
    reducedMotion: reducedMotion.matches,
    interactive: state.interactive,
    nativeBridge: hasNativeBridge(),
    hour,
    elapsedSeconds: elapsed,
    behavior,
    anchor: state.currentAnchor,
    scene: state.activeScene,
    forcedScene: state.forcedScene,
    loadedScenes: [...state.loadedScenes],
    periodWeights: periodWeightsAt(hour),
    sceneWeights: sceneWeightsAt(elapsed),
    sceneLayerOpacities: sourceOverOpacities(sceneWeightsAt(elapsed), [...state.sceneElements.keys()]),
    bounds: state.bounds ? { ...state.bounds } : null,
    grounding: grounding?.status() ?? null,
    reaction: state.reaction ? state.reaction.type : null,
    emotion: state.emotion,
    bones: requiredBones,
    availableMorphs: Object.keys(state.morphs)
  };
}

window.mikuCompanion = Object.freeze({
  setPreview(hour = null, elapsedSeconds = null) {
    state.previewHour = hour === null ? null : normalizeHour(hour);
    const elapsed = elapsedSeconds === null ? null : Number(elapsedSeconds);
    if (elapsed !== null && !Number.isFinite(elapsed)) throw new TypeError('elapsedSeconds must be finite');
    state.previewElapsed = elapsed;
    renderState(performance.now());
    return status();
  },
  setInteractive(enabled) {
    state.interactive = showsCharacter && Boolean(enabled);
    document.body.classList.toggle('interaction-enabled', state.interactive);
    if (!state.interactive) state.pointer = null;
    updateCharacterBounds(performance.now());
    return status();
  },
  interact(payload = {}) {
    if (!showsCharacter || !payload || typeof payload !== 'object' || !INTERACTION_TYPES.has(payload.type)) return false;
    const started = startReaction(payload.type, payload);
    renderState(performance.now());
    return started ? status() : false;
  },
  receiveReply(payload = {}) {
    if (!showsCharacter || !payload || typeof payload !== 'object') return false;
    const emotion = ALLOWED_EMOTIONS.has(payload.emotion) ? payload.emotion : 'calm';
    const action = ALLOWED_REPLY_ACTIONS.has(payload.action) ? payload.action : 'idle';
    state.emotion = emotion;
    showBubble(typeof payload.text === 'string' ? payload.text : '', emotion);
    if (action === 'wave' || action === 'stretch' || action === 'rest') startReaction(action);
    else if (action === 'nod') startReaction('hello');
    else state.reaction = null;
    renderState(performance.now());
    return status();
  },
  setScene(id = null) {
    const normalized = id === null || id === 'auto' ? null : String(id);
    if (normalized !== null && !state.loadedScenes.includes(normalized)) return false;
    state.forcedScene = normalized;
    renderState(performance.now());
    return status();
  },
  status
});

document.body.classList.toggle('interaction-enabled', state.interactive);

window.addEventListener('resize', () => {
  resize();
  renderState(performance.now());
}, { passive: true });

document.addEventListener('visibilitychange', () => {
  if (document.hidden) stopLoop();
  else {
    renderState(performance.now());
    startLoop();
  }
}, { passive: true });

window.addEventListener('focus', () => renderState(performance.now()), { passive: true });
reducedMotion.addEventListener('change', () => renderState(performance.now()));

try {
  if (showsBackground) await prepareScenes();
  else state.loadedScenes = SCENE_CONFIGS.map(config => config.id);
  if (showsCharacter) {
    fallbackPortrait.src = fallbackPortrait.dataset.src;
    setupRenderer();
    await loadModel();
  } else {
    state.mode = 'background';
    state.behavior = 'background';
  }
  renderState(performance.now());
  startLoop();
} catch (error) {
  state.error = error?.message || String(error);
  state.mode = 'fallback';
  applyBackground(currentHour(), currentElapsed());
}
