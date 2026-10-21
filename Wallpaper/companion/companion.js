import * as THREE from 'three';
import { createGrounding } from './grounding.js';
import { createWalking } from './walking.js';
import { createCarry } from './carry.js';
import { createTouchGestures } from './touch-gestures.js';
import { createRoutine, createVariety } from './variety.js';
import { characterEnvironment, defaultWeather, normalizeWeather, timeAnchors } from './environment.js';
import { createAmbient } from './ambient.js';
import { OutlineEffect } from './vendor/effects/OutlineEffect.js';

const canvas = document.querySelector('#webglCanvas');
const sceneRoot = document.querySelector('#sceneRoot');
const fallbackPortrait = document.querySelector('#fallbackPortrait');
const speechBubble = document.querySelector('#speechBubble');
const ambientCanvas = document.querySelector('#ambientCanvas');
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

let TIME_ANCHORS = timeAnchors();

const SCENE_CONFIGS = [
  {
    id: 'shibuya',
    day: '../assets/scenes/shibuya-hachiko.png',
    dusk: '../assets/scenes/shibuya-hachiko.png',
    night: '../assets/scenes/shibuya-hachiko.png'
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
const INTERACTION_TYPES = new Set(['headPat', 'headStroke', 'poke', 'wave', 'stretch', 'rest', 'hello', 'look', 'move']);
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
  renderedAt: 0,
  pinnedAnchor: null,
  sceneSlotSeconds: 300,
  thinking: false,
  weather: defaultWeather(),
  sunrise: 6,
  sunset: 17.75,
  ambientEnabled: true,
  hover: null,
  hoverBlend: 0,
  motionSource: null,
  motionTransition: null,
  lastModelElapsed: null,
  nextHoverGreeting: 0,
  nextHoverHaptic: 0,
  nextTouchSpeech: 0,
  language: 'zh-Hant'
};

const HOVER_PHRASES = {
  'zh-Hant': {
    head: ['要摸摸頭嗎？♪', '嘿嘿～', '頭髮今天也很順喔！', '想摸就摸吧♪', '咦，在看我的雙馬尾？'],
    hand: ['要擊掌嗎？', '嗨～♪', '牽手？', '來，伸手♪', '要一起去哪裡嗎？'],
    body: ['嗯？找我嗎？', '♪～', '在這裡喔！', '在忙什麼呀？', '要聽我唱歌嗎？♪']
  },
  en: {
    head: ['Head pats? ♪', 'Hehe~', 'Careful with the twintails!', 'Go on, I don\'t mind ♪', 'Looking at my twintails?'],
    hand: ['High five?', 'Hi~ ♪', 'Hold hands?', 'Here, give me your hand ♪', 'Going somewhere together?'],
    body: ['Hm? Need me?', '♪~', "I'm right here!", "What are you working on?", 'Want me to sing for you? ♪']
  },
  ja: {
    head: ['なでなでする？♪', 'えへへ～', 'ツインテ、崩さないでね！', 'なでてもいいよ♪', 'ツインテ見てるの？'],
    hand: ['ハイタッチする？', 'やっほー♪', '手、つなぐ？', 'ほら、手出して♪', 'どこか一緒に行く？'],
    body: ['ん？呼んだ？', '♪～', 'ここにいるよ！', '何してるの？', '歌ってあげようか？♪']
  }
};
const HOVER_NOTE_SYMBOLS = ['♪', '♫', '♬', '♪'];
const TOUCH_PHRASES = {
  'zh-Hant': {
    headStroke: ['嘿嘿～再摸一下♪', '頭髮要輕輕摸喔。', '好舒服…♪', '這樣摸會上癮的啦～', '呼嚕呼嚕～♪', '嗯…今天特別溫柔呢。'],
    handHold: ['牽好囉♪', '一起待一會吧。', '你的手好暖。', '不要放開喔～', '嘿嘿，有點害羞…'],
    poke: ['嗯？是你呀♪', '嘿，別鬧啦～♪', '戳什麼戳～', '好癢！', '哼，偷襲！', '要我陪你玩嗎？'],
    carry: ['哇！要帶我去哪？', '好、好高！', '放我下來啦～', '飛起來囉♪', '小心不要摔到我喔！'],
    teased: ['今天好黏人呢～♪', '再摸下去我會害羞的…', '你是不是很閒呀？♪', '好啦好啦，我知道你喜歡我♪', '休息一下吧，我又不會跑掉。']
  },
  en: {
    headStroke: ['Hehe~ one more pat? ♪', 'Gentle with the twintails!', 'That feels nice… ♪', 'I could get used to this~', 'Mmm~ ♪', "You're extra gentle today."],
    handHold: ["I've got your hand! ♪", "Let's stay like this a little.", 'Your hand is warm.', "Don't let go, okay?", 'Hehe, this is a bit embarrassing…'],
    poke: ['Hm? Oh, you! ♪', 'Hey, that tickles~ ♪', 'Poke poke~', 'Eek! Sneak attack!', 'Want me to play with you?', 'Hmph!'],
    carry: ['Whoa! Where are we going?', "S-so high!", 'Put me down~', "I'm flying! ♪", "Don't drop me!"],
    teased: ["You're so clingy today~ ♪", "If you keep that up I'll get shy…", "Haven't you got work to do? ♪", 'Okay okay, I know you like me ♪', "Take a break — I'm not going anywhere."]
  },
  ja: {
    headStroke: ['えへへ、もう一回♪', '髪は優しくなでてね。', 'きもちいい…♪', 'くせになっちゃうよ～', 'ふにゃ～♪', '今日はとっても優しいね。'],
    handHold: ['手、つないだね♪', 'もう少しこのままでいよう。', 'きみの手、あったかい。', '離さないでね？', 'えへへ、ちょっと照れる…'],
    poke: ['ん？きみかぁ♪', 'もう、くすぐったいよ～♪', 'つんつん～', 'ひゃっ！不意打ち！', '遊んでほしいの？', 'むー！'],
    carry: ['わっ！どこ行くの？', 'た、高い！', 'おろして～', '飛んでる～♪', '落とさないでね！'],
    teased: ['今日は甘えんぼさんだね～♪', 'そんなにされたら照れちゃう…', 'ひまなの？♪', 'はいはい、わたしのこと好きなんだね♪', '少し休もう？わたしはどこにも行かないよ。']
  }
};

const CONTEXT_PHRASES = {
  'zh-Hant': {
    morning: ['早安！今天也一起加油♪', '早上好～吃早餐了沒？'],
    night: ['這麼晚了，要早點休息喔。', '夜深了，我陪你多一會吧。'],
    rain: ['外面在下雨呢，記得帶傘。', '雨聲好好聽…'],
    storm: ['打雷了…有點可怕。', '外面風雨好大，留在室內吧。'],
    snow: ['下雪了！好漂亮♪', '好冷～要穿暖一點喔。'],
    fog: ['外面霧好大呢。']
  },
  en: {
    morning: ["Morning! Let's do our best today ♪", 'Good morning~ had breakfast yet?'],
    night: ["It's late — don't stay up too long.", "It's late… I'll keep you company a bit longer."],
    rain: ["It's raining — remember your umbrella.", 'I love the sound of rain…'],
    storm: ["Thunder… that's a bit scary.", "It's wild out there — stay inside."],
    snow: ["It's snowing! So pretty ♪", 'Brr~ wrap up warm!'],
    fog: ["It's so foggy outside."]
  },
  ja: {
    morning: ['おはよう！今日もがんばろ♪', 'おはよ～、朝ごはん食べた？'],
    night: ['もう遅いよ、早めに休んでね。', '夜更かしさんだね…もう少しだけ一緒にいるよ。'],
    rain: ['雨降ってるね、傘忘れないで。', '雨の音、すき…'],
    storm: ['雷…ちょっと怖いね。', '外は大荒れだね、おうちにいよう。'],
    snow: ['雪だ！きれい♪', 'さむ～い、あったかくしてね。'],
    fog: ['外、霧がすごいね。']
  }
};
const HOVER_GREETING_COOLDOWN = 40;
const HOVER_DWELL_SECONDS = 2.2;

const SCENE_FADE_SECONDS = 8;
const ambient = showsBackground && ambientCanvas ? createAmbient(ambientCanvas) : null;
ambient?.resize();
const BACKGROUND_IDLE_INTERVAL = 1000;

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

  const slot = Math.max(30, state.sceneSlotSeconds);
  const fadeStart = slot - SCENE_FADE_SECONDS;
  const cycle = slot * ids.length;
  // Wall-clock based so the background and character pages always agree on the scene.
  const clock = state.previewElapsed !== null ? elapsed : Date.now() / 1000;
  const time = ((clock % cycle) + cycle) % cycle;
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

const bubbleName = document.createElement('span');
bubbleName.className = 'bubble-name';
bubbleName.textContent = 'MIKU';
const bubbleText = document.createElement('span');
bubbleText.className = 'bubble-text';
speechBubble.replaceChildren(bubbleName, bubbleText);

function showBubble(text, emotion = 'calm', duration = null) {
  if (!showsCharacter) return;
  const safeText = typeof text === 'string' ? text.trim().slice(0, 240) : '';
  if (!safeText) return;
  const safeEmotion = ALLOWED_EMOTIONS.has(emotion) ? emotion : 'calm';
  state.thinking = false;
  speechBubble.classList.remove('thinking');
  bubbleText.textContent = safeText;
  speechBubble.dataset.emotion = safeEmotion;
  speechBubble.classList.add('visible');
  clearTimeout(state.bubbleTimer);
  // Longer replies stay up longer so they can actually be read.
  const visibleFor = duration ?? THREE.MathUtils.clamp(3800 + [...safeText].length * 110, 4200, 14000);
  state.bubbleTimer = window.setTimeout(() => speechBubble.classList.remove('visible'), visibleFor);
}

function setThinking(thinking) {
  if (!showsCharacter) return;
  state.thinking = Boolean(thinking);
  clearTimeout(state.bubbleTimer);
  if (state.thinking) {
    bubbleText.textContent = '♪ ♫ ♪';
    speechBubble.dataset.emotion = 'calm';
    speechBubble.classList.add('thinking', 'visible');
    // Safety net in case the reply never arrives.
    state.bubbleTimer = window.setTimeout(() => speechBubble.classList.remove('visible', 'thinking'), 120000);
  } else if (speechBubble.classList.contains('thinking')) {
    speechBubble.classList.remove('visible', 'thinking');
  }
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
    headStroke: 2.2,
    poke: 1.5,
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
    : durations[type] * variety.range(0.88, 1.14);
  if (options.touch) variety.noteTouch(elapsed);

  if (type === 'headStroke' && state.reaction?.type === type && elapsed < state.reaction.end) {
    state.reaction.end = elapsed + duration * 0.65;
    state.reaction.duration = state.reaction.end - state.reaction.start;
    holdAnchor(state.currentAnchor, elapsed, duration + 8);
    return true;
  }

  state.reaction = {
    type,
    touch: Boolean(options.touch),
    side: options.side === '右' ? '右' : '左',
    variant: options.variant ?? chooseVariant(type),
    start: elapsed,
    end: elapsed + duration,
    duration,
    fromAnchor: state.currentAnchor,
    toAnchor: targetAnchor
  };
  holdAnchor(type === 'move' ? targetAnchor : state.currentAnchor, elapsed, duration + 8);

  if ((type === 'look' || type === 'headPat' || type === 'headStroke') && Number.isFinite(Number(options.x))) {
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
let rimLight;
let outline;
const lightningColor = new THREE.Color(0xdfe8ff);
const EMISSIVE_DUSK = [1.08, 0.86, 0.8];
const WAVE_POSE = { armRaise: 1.32, armForward: -0.32, elbow: 1.15, swing: 0.32, palmTwist: -0.9 };
const EMISSIVE_NIGHT = [0.78, 0.88, 1.08];
let grounding;
let walking;
const carry = createCarry({ maxHeight: 6 });
const touchGestures = createTouchGestures();
// Separate detector for rubbing her head while the button is held.
const rubGestures = createTouchGestures();
// Every reaction, idle moment and line is drawn fresh, so she never plays the same clip twice in a row.
const variety = createVariety();
const routine = createRoutine({ seed: (Date.now() ^ Math.floor(Math.random() * 1e9)) >>> 0, startAnchor: POSITION_ANCHORS[0] });

const REACTION_STYLES = {
  wave: ['big', 'small', 'tilt'],
  headPat: ['melt', 'shy', 'giggle', 'proud'],
  headStroke: ['melt', 'shy', 'giggle', 'proud'],
  poke: ['wink', 'surprised', 'pout', 'flustered'],
  hello: ['nod', 'curious', 'bounce'],
  stretch: ['plain', 'yawn', 'side'],
  handHold: ['swing', 'shy', 'happy'],
  carry: ['surprised', 'wheee', 'shy']
};

function chooseVariant(type) {
  // The more often she's been touched recently, the shyer (and cheekier) she gets.
  const mood = variety.mood(currentElapsed());
  const weights = mood > 0.45 ? { shy: 2.6, flustered: 2.3, pout: 1.8, giggle: 1.4 } : {};
  const styles = REACTION_STYLES[type];
  return {
    style: styles ? variety.pick(type, styles, weights) : null,
    speed: variety.range(0.86, 1.16),
    amplitude: variety.range(0.82, 1.18),
    flip: variety.chance(0.5) ? 1 : -1
  };
}
let carryPose = carry.status();
const raycaster = new THREE.Raycaster();
const pointerNdc = new THREE.Vector2();
const hitLocalPosition = new THREE.Vector3();
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

  // Back light that picks out her silhouette at dusk and under neon.
  rimLight = new THREE.DirectionalLight(0xbfe6ff, 0);
  rimLight.position.set(6, 12, -18);
  scene.add(rimLight);

  grounding = createGrounding(scene);
  // Contact shadows are not part of the character: no ink lines for them.
  scene.traverse(object => {
    if (object.material) object.material.userData.outlineParameters = { visible: false };
  });
  // MMD-style ink outlines, using each material's own edge size and colour from the model.
  outline = new OutlineEffect(renderer, {
    defaultThickness: 0.0028,
    defaultColor: [0.12, 0.16, 0.22],
    defaultAlpha: 0.85,
    defaultKeepAlive: true
  });

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
  // The bubble is translated up by its own height, so this is where its tail points.
  speechBubble.style.top = `${Math.max(0.2, rect.y - 0.012) * 100}%`;
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
  let zone = 'body';
  if (normalizedHeight >= 0.73) zone = 'head';
  else if (normalizedHeight >= 0.43 && lateral >= 0.19) zone = 'hand';
  else if (normalizedHeight >= 0.4) zone = 'torso';
  state.model.worldToLocal(hitLocalPosition.copy(hit.point));
  return { hit, zone, normalizedHeight, lateral, side: hitLocalPosition.x >= 0 ? '左' : '右' };
}

const euler = new THREE.Euler();
const quaternion = new THREE.Quaternion();
const twistAxis = new THREE.Vector3();
const twistRotation = new THREE.Quaternion();

function resetSkeleton() {
  for (const [bone, rest] of state.restPose) {
    bone.position.copy(rest.position);
    bone.quaternion.copy(rest.quaternion);
    bone.scale.copy(rest.scale);
  }
}

function captureRenderedPose() {
  const bones = new Map();
  for (const bone of state.restPose.keys()) {
    bones.set(bone, {
      position: bone.position.clone(),
      quaternion: bone.quaternion.clone()
    });
  }
  return {
    bones,
    morphs: state.model?.morphTargetInfluences?.slice() ?? null,
    rootQuaternion: state.model.quaternion.clone()
  };
}

const blendPosition = new THREE.Vector3();
const blendQuaternion = new THREE.Quaternion();

function updateMotionSource(source, elapsed) {
  if (reducedMotion.matches) {
    state.motionSource = source;
    state.motionTransition = null;
    return;
  }
  if (state.motionSource !== null && state.motionSource !== source) {
    state.motionTransition = { ...captureRenderedPose(), start: elapsed };
  }
  state.motionSource = source;
}

function blendMotionTransition(elapsed) {
  const transition = state.motionTransition;
  if (!transition) return;
  const weight = smoothstep((elapsed - transition.start) / 0.27);
  for (const [bone, from] of transition.bones) {
    blendPosition.copy(bone.position);
    bone.position.lerpVectors(from.position, blendPosition, weight);
    blendQuaternion.copy(bone.quaternion);
    bone.quaternion.slerpQuaternions(from.quaternion, blendQuaternion, weight);
  }
  const influences = state.model?.morphTargetInfluences;
  if (influences && transition.morphs) {
    for (let index = 0; index < influences.length; index += 1) {
      influences[index] = THREE.MathUtils.lerp(transition.morphs[index] ?? 0, influences[index], weight);
    }
  }
  blendQuaternion.copy(state.model.quaternion);
  state.model.quaternion.slerpQuaternions(transition.rootQuaternion, blendQuaternion, weight);
  if (weight >= 1) state.motionTransition = null;
}

function rotateBone(name, x = 0, y = 0, z = 0, weight = 1) {
  const bone = state.bones.get(name);
  if (!bone || weight === 0) return;
  euler.set(x * weight, y * weight, z * weight, 'XYZ');
  quaternion.setFromEuler(euler);
  bone.quaternion.multiply(quaternion);
}

function twistBone(name, childName, angle, weight = 1) {
  const bone = state.bones.get(name);
  const child = state.bones.get(childName);
  if (!bone || !child || weight === 0) return;

  const childRest = state.restPose.get(child);
  if (!childRest) return;
  twistAxis.copy(childRest.position);

  let parent = child.parent;
  while (parent && parent !== bone) {
    const parentRest = state.restPose.get(parent);
    if (!parentRest) return;
    twistAxis.multiply(parentRest.scale).applyQuaternion(parentRest.quaternion).add(parentRest.position);
    parent = parent.parent;
  }
  if (parent !== bone || twistAxis.lengthSq() < 1e-8) return;

  twistRotation.setFromAxisAngle(twistAxis.normalize(), angle * weight);
  bone.quaternion.multiply(twistRotation);
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
  // Open-ended, seeded routine: different every launch, never a fixed loop.
  return routine.behaviorAt(elapsed);
}

function anchorAt(elapsed, behavior) {
  if (behavior.name === 'walk') {
    const from = behavior.fromAnchor;
    const to = behavior.toAnchor;
    return THREE.MathUtils.lerp(from, to, walkingProgress(from, to, behavior.progress, behavior.duration));
  }
  return routine.restingAnchorAt(elapsed);
}

function walkingProgress(fromAnchor, toAnchor, progress, duration) {
  const distance = Math.abs(screenAnchorToWorld(toAnchor) - screenAnchorToWorld(fromAnchor));
  const travelDuration = Math.min(duration, Math.max(1.2, distance / 3.1));
  return smoothstep(progress * duration / travelDuration);
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
  const lookXTarget = faceAnchor ? THREE.MathUtils.clamp((trackedLook.x - faceAnchor.x) * 0.3, -0.16, 0.16) : 0;
  const lookYTarget = faceAnchor ? THREE.MathUtils.clamp((trackedLook.y - faceAnchor.y) * 0.2, -0.1, 0.1) : 0;
  // Eyes lead, the head follows a moment later and settles softly.
  const eyeX = springTo(springs.eyeX, lookXTarget, 7, 0.9);
  const eyeY = springTo(springs.eyeY, lookYTarget, 7, 0.9);
  const lookX = springTo(springs.lookX, lookXTarget, 2.2, 0.75);
  const lookY = springTo(springs.lookY, lookYTarget, 2.2, 0.75);
  const bob = springTo(springs.bob, 0, 3.2, 0.32);
  const jolt = springTo(springs.jolt, 0, 2.6, 0.38);
  offsetBone('センター', 0, 0.035 * breath + bob * 0.09, 0);
  rotateBone('上半身', 0.018 * breath - bob * 0.05, 0, 0.018 * Math.sin(elapsed * 0.42) + jolt * 0.04);
  rotateBone('首', 0.018 + lookY * 0.3, 0.035 * gaze + lookX * 0.3, -0.018 * gaze + jolt * 0.05);
  rotateBone('頭', -0.015 + lookY * 0.45 - bob * 0.06, 0.045 * gaze + lookX * 0.5, 0.035 * Math.sin(elapsed * 0.23) + jolt * 0.09);
  rotateBone('両目', 0.006 * Math.sin(elapsed * 0.37) + eyeY, 0.025 * gaze + eyeX, 0);

  rotateBone('左腕', 0.03, 0, -0.50);
  rotateBone('右腕', -0.03, 0, 0.50);
  rotateBone('左ひじ', 0.04, 0.02, 0.12);
  rotateBone('右ひじ', -0.04, -0.02, -0.12);
  rotateBone('左手首', 0.03, 0, -0.06);
  rotateBone('右手首', -0.03, 0, 0.06);

  const hairTrail = THREE.MathUtils.clamp(springs.hair.x, -0.055, 0.055);
  const sway = Math.sin(elapsed * 0.72) * 0.018;
  const swayWeights = [1, 0.65, 0.4];
  ['左髪１', '左髪２', '左髪３'].forEach((name, index) => {
    rotateBone(name, 0.012 + index * 0.006, 0, sway * swayWeights[index] + (index === 0 ? hairTrail : 0));
  });
  ['右髪１', '右髪２', '右髪３'].forEach((name, index) => {
    rotateBone(name, 0.012 + index * 0.006, 0, -sway * swayWeights[index] + (index === 0 ? hairTrail : 0));
  });
  rotateBone('前髪１', 0.008 * breath, 0, 0.006 * gaze);
  rotateBone('前髪２', 0.009 * breath, 0, 0);
  rotateBone('前髪３', 0.008 * breath, 0, -0.006 * gaze);

  setMorph('まばたき', blinkAmount(elapsed));
  setSmile(0.12 + 0.04 * Math.sin(elapsed * 0.29));
  if (state.emotion === 'happy') setSmile(0.32);
  if (state.emotion === 'sleepy') setMorph('まばたき', Math.max(blinkAmount(elapsed), 0.18));
  if (state.emotion === 'curious') rotateBone('頭', 0, 0.035, 0.045);

  // Cursor resting on Miku: she brightens up and tilts her head towards it.
  const hover = state.hoverBlend;
  if (hover > 0.001) {
    const base = state.emotion === 'happy' ? 0.32 : 0.12;
    setSmile(Math.max(base, 0.14 + hover * (state.hover?.zone === 'head' ? 0.5 : 0.38)));
    const tilt = state.hover?.side ?? 1;
    rotateBone('頭', -0.025 * hover, 0.02 * tilt * hover, 0.07 * tilt * hover);
    rotateBone('上半身', -0.012 * hover, 0, 0.012 * tilt * hover);
  }
  // A light blush when she's happy or you're paying her attention.
  const blush = Math.max(state.emotion === 'happy' ? 0.22 : 0, hover * (state.hover?.zone === 'head' ? 0.55 : 0.38));
  if (blush > 0.001) setMorph('照れ', blush);
}

function applyWave(progress, elapsed, side = '左', variant = null) {
  const style = variant?.style ?? 'big';
  const amplitude = variant?.amplitude ?? 1;
  const cycles = 5.6 * (variant?.speed ?? 1) + (style === 'small' ? 1.6 : 0);
  // Staged: raise the arm, bend the elbow, wave from the elbow, then lower.
  const bend = easeBetween(progress, 0, 0.13) * (1 - easeBetween(progress, 0.89, 1));
  const raise = easeBetween(progress, 0.035, 0.18) * (1 - easeBetween(progress, 0.78, 0.94));
  const swingAmount = easeBetween(progress, 0.12, 0.22) * (1 - easeBetween(progress, 0.72, 0.84));
  const swing = Math.sin((progress - 0.12) * Math.PI * 2 * cycles) * swingAmount
    * amplitude * (style === 'small' ? 0.62 : 1);
  const lift = style === 'small' ? 0.78 : 1;
  const sign = side === '右' ? -1 : 1;
  rotateBone(`${side}肩`, 0, 0, sign * 0.12, raise);
  rotateBone(`${side}腕`, 0, sign * WAVE_POSE.armForward, sign * WAVE_POSE.armRaise * lift, raise);
  rotateBone(`${side}ひじ`, 0, 0, sign * (WAVE_POSE.elbow + (style === 'small' ? 0.18 : 0) + WAVE_POSE.swing * swing), bend);
  // Rotate the sleeve and hand together to keep the cuff aligned.
  twistBone(`${side}ひじ`, `${side}手首`, sign * WAVE_POSE.palmTwist, bend);
  // The body follows the arm a little.
  rotateBone('上半身', 0, sign * 0.03 * raise, sign * (-0.035 * raise + 0.014 * swing));
  rotateBone('頭', 0.02 * raise, -sign * 0.09 * raise, sign * (-0.1 * raise + 0.025 * swing));
  if (style === 'tilt') {
    rotateBone('頭', 0, 0, -sign * 0.09 * raise);
    setMorph(side === '右' ? 'ウィンク右' : 'ウィンク', 0.75 * swingAmount);
  }
  setSmile(Math.max(0.12, (style === 'small' ? 0.8 : 0.67) * raise));
  setMorph('ω', 0.16 * raise);
  setMorph('照れ', (style === 'small' ? 0.45 : 0.28) * raise);
  setMorph('笑い', 0.08 * raise * Math.max(0, Math.sin(elapsed * 1.7)));
}

function applyStretch(progress, variant = null) {
  const weight = gestureEnvelope(progress);
  const rise = Math.sin(Math.PI * progress);
  if (variant?.style === 'yawn') {
    setMorph('あ', 0.55 * rise * weight);
    setMorph('まばたき', 0.75 * rise * weight);
  } else if (variant?.style === 'side') {
    rotateBone('上半身', 0, 0, 0.12 * (variant.flip ?? 1) * rise * weight);
  }
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

/** Sideways skirt trail from horizontal motion (models with a full skirt rig). */
// ---- Turning: a sequenced, springy turn instead of a rigid spin ----------------
//
// The gait asks for a body angle; she reaches it on a soft spring (eases in, settles
// with a little overshoot). Whatever the body hasn't caught up with yet is "lead":
// eyes and head point there first, shoulders follow, hips come last. The spin speed
// throws the twintails and skirt outward and makes them trail behind.

const turning = { yaw: { x: 0, v: 0 }, hair: { x: 0, v: 0 } };
const TURN_ANGLE = 1.22;

function applyTurnFollowThrough(gaitPose) {
  const target = gaitPose.active ? gaitPose.direction * TURN_ANGLE * gaitPose.turn : 0;
  if (reducedMotion.matches) {
    turning.yaw.x = target;
    turning.yaw.v = 0;
    state.model.rotation.y = target;
    return;
  }
  const yaw = springTo(turning.yaw, target, 1.55, 0.74);
  const spin = THREE.MathUtils.clamp(turning.yaw.v, -7, 7); // rad/s, + = turning to her left
  const lead = THREE.MathUtils.clamp(target - yaw, -0.9, 0.9);
  state.model.rotation.y = yaw;

  // Hair lags the spin a beat behind and swings back past centre when she stops.
  const hair = springTo(turning.hair, spin, 2.1, 0.45);
  if (Math.abs(lead) < 0.002 && Math.abs(spin) < 0.01 && Math.abs(hair) < 0.01) return;

  // Eyes lead, then head and neck, then shoulders; the hips counter a little.
  rotateBone('両目', 0, lead * 0.35, 0);
  rotateBone('首', 0, lead * 0.28, 0);
  rotateBone('頭', 0, lead * 0.3, -spin * 0.012);
  rotateBone('上半身', 0, lead * 0.22, -spin * 0.022);
  rotateBone('下半身', 0, -lead * 0.07, spin * 0.008);

  // Twintails: lag behind the turn (swing front/back) and flare outward (centrifugal).
  const lag = THREE.MathUtils.clamp(hair * 0.075, -0.32, 0.32);
  const flare = THREE.MathUtils.clamp(Math.abs(hair) * 0.03, 0, 0.14);
  const chain = [1, 0.6, 0.4];
  ['左髪１', '左髪２', '左髪３'].forEach((name, index) => rotateBone(name, -lag * chain[index], 0, flare * chain[index]));
  ['右髪１', '右髪２', '右髪３'].forEach((name, index) => rotateBone(name, lag * chain[index], 0, -flare * chain[index]));
  // Skirt swings round with the hips and lags behind.
  applySkirtTrail(THREE.MathUtils.clamp(-hair * 0.012, -0.045, 0.045));
}

function applySkirtTrail(amount) {
  const trail = THREE.MathUtils.clamp(amount, -0.045, 0.045);
  if (Math.abs(trail) < 0.001) return;
  if (state.bones.has('スカート_0_0')) {
    for (let index = 0; index < 8; index += 1) {
      rotateBone(`スカート_0_${index}`, 0, 0, trail);
    }
    return;
  }
  for (const name of ['左ｽｶｰﾄ前', '左ｽｶｰﾄ後', '右ｽｶｰﾄ前', '右ｽｶｰﾄ後']) rotateBone(name, 0, 0, trail);
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

function applyHeadPat(progress, variant = null) {
  const weight = gestureEnvelope(progress);
  const style = variant?.style ?? 'melt';
  const flip = variant?.flip ?? 1;
  const nuzzle = Math.sin(progress * Math.PI * 3 * (variant?.speed ?? 1)) * weight;
  rotateBone('首', 0.035, -0.025 * flip, 0.1 * flip, weight);
  rotateBone('頭', 0.05 + 0.025 * nuzzle, -0.04 * flip, 0.12 * flip, weight);
  rotateBone('左髪１', 0.025, 0, 0.035 * nuzzle, weight);
  rotateBone('右髪１', 0.025, 0, -0.035 * nuzzle, weight);
  const blink = blinkAmount(state.previewElapsed ?? state.activeElapsed);
  switch (style) {
    case 'shy':
      // Looks down and away, eyes open, very red.
      rotateBone('頭', 0.1 * weight, 0.1 * flip * weight, 0);
      setMorph('まばたき', Math.max(blink, 0.25 * weight));
      setMorph('照れ', 0.95 * weight);
      setSmile(Math.max(0.12, 0.45 * weight));
      break;
    case 'giggle':
      rotateBone('頭', 0, 0, 0.03 * Math.sin(progress * Math.PI * 12) * weight);
      setMorph('まばたき', Math.max(blink, 0.6 * weight));
      setMorph('笑い', 0.55 * weight * (0.5 + 0.5 * Math.sin(progress * Math.PI * 10)));
      setMorph('照れ', 0.5 * weight);
      setSmile(Math.max(0.12, 0.8 * weight));
      break;
    case 'proud':
      // Chin up, a pleased little smirk.
      rotateBone('頭', -0.08 * weight, 0, 0);
      setMorph('まばたき', blink);
      setMorph('にやり', 0.6 * weight);
      setMorph('照れ', 0.3 * weight);
      setSmile(Math.max(0.12, 0.5 * weight));
      break;
    default:
      setMorph('まばたき', Math.max(blink, 0.72 * weight));
      setMorph('なごみ', 0.35 * weight);
      setSmile(Math.max(0.12, 0.74 * weight));
      setMorph('ω', 0.12 * weight);
      setMorph('照れ', 0.7 * weight);
  }
}

function applyHandHold(progress, elapsed, side, variant = null) {
  const weight = smoothstep(progress);
  const style = variant?.style ?? 'swing';
  const sign = side === '右' ? -1 : 1;
  const sway = Math.sin(elapsed * 2.8 * (variant?.speed ?? 1)) * (style === 'swing' ? 0.07 : 0.03);
  rotateBone(`${side}肩`, 0, 0, sign * 0.06, weight);
  rotateBone(`${side}腕`, 0, -sign * 0.14, sign * 0.72, weight);
  rotateBone(`${side}ひじ`, 0, 0, sign * (0.45 + sway), weight);
  twistBone(`${side}ひじ`, `${side}手首`, -sign * 0.45, weight);
  if (style === 'shy') {
    rotateBone('頭', 0.07 * weight, sign * 0.15 * weight, sign * 0.04 * weight);
    setMorph('照れ', 0.9 * weight);
    setSmile(0.4 * weight);
  } else if (style === 'happy') {
    offsetBone('センター', 0, 0.07 * Math.abs(Math.sin(elapsed * 5.2)) * weight, 0);
    rotateBone('頭', 0.015 * weight, -sign * 0.04 * weight, -sign * 0.08 * weight);
    setMorph('にっこり', 0.5 * weight);
    setSmile(0.85 * weight);
    setMorph('照れ', 0.35 * weight);
  } else {
    rotateBone('頭', 0.015 * weight, -sign * 0.04 * weight, -sign * 0.06 * weight);
    setSmile(0.64 * weight);
    setMorph('照れ', 0.48 * weight);
  }
}

function applyPoke(progress, elapsed, side, variant = null) {
  const weight = gestureEnvelope(progress);
  const style = variant?.style ?? 'wink';
  const sign = side === '右' ? -1 : 1;
  const recoil = Math.sin(progress * Math.PI * 2) * weight;
  rotateBone('頭', -0.035 * weight, sign * 0.06 * weight, sign * 0.09 * recoil);
  rotateBone('上半身', 0, 0, sign * 0.025 * recoil);
  switch (style) {
    case 'surprised': {
      // Startled first, then breaks into a smile.
      const startle = easeBetween(progress, 0, 0.08) * (1 - easeBetween(progress, 0.3, 0.5));
      rotateBone('頭', -0.09 * startle, 0, 0);
      offsetBone('センター', 0, 0.08 * startle, 0);
      setMorph('びっくり', 0.9 * startle);
      setMorph('まばたき', blinkAmount(elapsed) * (1 - weight));
      setSmile(Math.max(0.12, 0.7 * weight * (1 - startle)));
      break;
    }
    case 'pout':
      rotateBone('頭', 0.03 * weight, sign * 0.12 * weight, 0);
      setMorph('じと目', 0.6 * weight);
      setMorph('口角下げ', 0.35 * weight);
      setMorph('ω', 0.3 * weight);
      setMorph('照れ', 0.35 * weight);
      break;
    case 'flustered':
      rotateBone('頭', 0, 0, 0.05 * Math.sin(progress * Math.PI * 9) * weight);
      setMorph('はぅ', 0.8 * weight);
      setMorph('照れ', 0.9 * weight);
      setSmile(Math.max(0.12, 0.35 * weight));
      break;
    default:
      setMorph(side === '右' ? 'ウィンク右' : 'ウィンク', 0.7 * weight);
      setMorph('まばたき', blinkAmount(elapsed) * (1 - weight));
      setMorph('照れ', 0.4 * weight);
      setSmile(Math.max(0.12, 0.66 * weight));
  }
}

function applyLookAround(progress, variant = null) {
  // Glances one way, then the other, then back; eyes lead the head.
  const flip = variant?.flip ?? 1;
  const first = easeBetween(progress, 0.05, 0.22) * (1 - easeBetween(progress, 0.42, 0.58));
  const second = easeBetween(progress, 0.48, 0.64) * (1 - easeBetween(progress, 0.82, 0.97));
  const yaw = (first - second) * 0.32 * flip * (variant?.amplitude ?? 1);
  const up = Math.sin(progress * Math.PI) * 0.04;
  rotateBone('首', -up * 0.5, yaw * 0.4, 0);
  rotateBone('頭', -up, yaw * 0.6, -yaw * 0.12);
  rotateBone('両目', 0, yaw * 0.5, 0);
  rotateBone('上半身', 0, yaw * 0.15, 0);
}

function applyHum(progress, elapsed, variant = null) {
  // Eyes closed, swaying to a tune only she can hear; little notes drift up.
  const weight = gestureEnvelope(progress);
  const tempo = 0.55 * (variant?.speed ?? 1);
  const sway = Math.sin(elapsed * Math.PI * 2 * tempo) * weight;
  offsetBone('センター', 0.05 * sway, 0.02 * Math.abs(sway), 0);
  rotateBone('上半身', 0, 0, 0.04 * sway);
  rotateBone('頭', 0, 0, 0.08 * sway);
  rotateBone('左髪１', 0, 0, -0.03 * sway);
  rotateBone('右髪１', 0, 0, -0.03 * sway);
  setMorph('まばたき', Math.max(blinkAmount(elapsed), 0.7 * weight));
  setMorph('なごみ', 0.55 * weight);
  setMorph('う', 0.22 * weight * (0.5 + 0.5 * Math.sin(elapsed * 7.3)));
  setSmile(Math.max(0.12, 0.35 * weight));
  if (weight > 0.5 && elapsed - (state.lastHumNote ?? -Infinity) > 0.85) {
    const face = projectedFaceAnchor();
    if (face) spawnHoverNote(face.x + (variant?.flip ?? 1) * 0.03, face.y - 0.03, 'hum');
    state.lastHumNote = elapsed;
  }
}

function applyNod(progress, curious = false, variant = null) {
  const weight = gestureEnvelope(progress);
  const style = variant?.style ?? (curious ? 'curious' : 'nod');
  const flip = variant?.flip ?? 1;
  const nod = Math.sin(progress * Math.PI * 4 * (variant?.speed ?? 1)) * weight;
  if (style === 'bounce') {
    offsetBone('センター', 0, 0.12 * Math.abs(Math.sin(progress * Math.PI * 4)) * weight, 0);
    rotateBone('頭', 0.04 * nod, 0, 0.06 * flip * weight);
    setSmile(Math.max(0.12, 0.7 * weight));
    setMorph('にっこり', 0.35 * weight);
    return;
  }
  const tilt = style === 'curious';
  rotateBone('首', 0.07 * nod, tilt ? 0.06 * flip * weight : 0, 0.025 * flip * weight);
  rotateBone('頭', 0.13 * nod, tilt ? 0.1 * flip * weight : 0, 0.045 * flip * weight);
  setSmile(Math.max(0.12, 0.46 * weight));
}

function applyWalk(pose) {
  const { direction, stride, weight } = pose;
  state.model.rotation.y = direction * 1.22 * pose.turn;
  offsetBone('センター', 0, Math.abs(stride) * 0.06 * weight, 0);
  rotateBone('上半身', 0.025, -0.05 * stride, 0, weight);
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
  let yaw = 0;
  let roll = 0;
  for (const name of ['上半身', '上半身2', '首', '頭']) {
    const bone = state.bones.get(name);
    const rest = state.restPose.get(bone);
    if (!bone || !rest) continue;
    quaternion.copy(rest.quaternion).invert().multiply(bone.quaternion);
    euler.setFromQuaternion(quaternion, 'XYZ');
    pitch += euler.x;
    yaw += euler.y;
    roll += euler.z;
  }
  // Long tails hang behind the body instead of swinging through it when the head tilts.
  const bias = state.bones.has('腰パーツ親') ? 0 : 0.04;
  const counterPitch = THREE.MathUtils.clamp(Math.max(0, -pitch) + bias, 0, 0.25);
  const counterYaw = THREE.MathUtils.clamp(-yaw * 0.65, -0.12, 0.12);
  const counterRoll = THREE.MathUtils.clamp(-roll * 0.8, -0.20, 0.20);
  rotateBone('左髪１', counterPitch, counterYaw, counterRoll);
  rotateBone('右髪１', counterPitch, counterYaw, counterRoll);
}

// ---- Springs: every interactive motion eases in, overshoots a little and settles ----

const springs = {
  lookX: { x: 0, v: 0 },
  lookY: { x: 0, v: 0 },
  eyeX: { x: 0, v: 0 },
  eyeY: { x: 0, v: 0 },
  anchor: { x: null, v: 0 },
  bob: { x: 0, v: 0 },
  jolt: { x: 0, v: 0 },
  hair: { x: 0, v: 0 },
  skirt: { x: 0, v: 0 }
};
let springDelta = 0;

/** Damped spring (implicit Euler, stable at any frame rate). */
function springTo(spring, target, frequency, damping = 1) {
  const delta = springDelta;
  if (delta <= 0) return spring.x;
  const omega = 2 * Math.PI * frequency;
  const f = 1 + 2 * delta * damping * omega;
  const oo = omega * omega;
  const hoo = delta * oo;
  const hhoo = delta * hoo;
  const inverse = 1 / (f + hhoo);
  const x = (f * spring.x + delta * spring.v + hhoo * target) * inverse;
  const v = (spring.v + hoo * (target - spring.x)) * inverse;
  spring.x = x;
  spring.v = v;
  return x;
}

function kick(spring, velocity) {
  spring.v += velocity;
}

function updateHoverBlend(elapsed, motionActive) {
  const previous = state.lastModelElapsed ?? elapsed;
  const delta = THREE.MathUtils.clamp(elapsed - previous, 0, 0.1);
  springDelta = delta;
  state.lastModelElapsed = elapsed;
  const target = state.hover && !motionActive ? 1 : 0;
  state.hoverBlend += (target - state.hoverBlend) * Math.min(1, delta * 7);
  if (Math.abs(target - state.hoverBlend) < 0.002) state.hoverBlend = target;
}

function updateModel(elapsed) {
  if (!state.model) return;
  carryPose = carry.update({ time: elapsed, reducedMotion: reducedMotion.matches });
  const carrying = carryPose.phase !== 'idle';
  if (carryPose.impact) postNative({ type: 'haptic' });
  let routineBehavior = behaviorAt(elapsed);
  let routineAnchor = anchorAt(elapsed, routineBehavior);
  if (state.pinnedAnchor !== null) {
    // Pinned by the user: keep the idle gestures but don't walk away.
    if (routineBehavior.name === 'walk') routineBehavior = { name: 'idle', progress: 0 };
    routineAnchor = state.pinnedAnchor;
  }
  const handHeld = state.pointer && !state.pointer.dragging && state.pointer.zone === 'hand';
  const pointerReaction = state.pointer?.dragging
    ? { type: 'drag', progress: 0.5, fromAnchor: state.currentAnchor, toAnchor: state.currentAnchor }
    : handHeld ? { type: 'handHold', side: state.pointer.side, variant: state.pointer.variant, progress: Math.min(1, (elapsed - state.pointer.started) / 0.35) } : null;
  if (handHeld && !carrying && !state.pointer.greeted && elapsed - state.pointer.started >= 0.6) {
    state.pointer.greeted = true;
    showTouchPhrase('handHold');
  }
  const carryReaction = carrying ? { type: carryPose.phase, progress: carryPose.landingProgress ?? 0.5 } : null;
  const reaction = reducedMotion.matches ? null : carryReaction || pointerReaction || activeReactionAt(elapsed);
  const behavior = reaction || (reducedMotion.matches ? { name: 'idle', progress: 0 } : routineBehavior);
  const source = reducedMotion.matches
    ? 'reduced'
    : carrying ? 'carry' : pointerReaction ? state.pointer : state.reaction || routineBehavior.name;
  updateHoverBlend(elapsed, Boolean(state.pointer || reaction || behavior.name === 'wave'));
  updateMotionSource(source, elapsed);
  resetSkeleton();
  resetMorphs();
  state.model.rotation.y = 0;
  let anchor = reducedMotion.matches
    ? (state.pinnedAnchor ?? POSITION_ANCHORS[1])
    : heldAnchorAt(routineAnchor, elapsed);
  if (reaction?.type === 'move') {
    anchor = THREE.MathUtils.lerp(
      reaction.fromAnchor,
      reaction.toAnchor,
      walkingProgress(reaction.fromAnchor, reaction.toAnchor, reaction.progress, reaction.duration)
    );
  }
  const dragging = Boolean(state.pointer?.dragging);
  if (dragging) anchor = state.anchorHold?.anchor ?? anchor;
  // Follow the target position with a soft spring: she trails the cursor while
  // dragged and sways to a stop when released.
  if (springs.anchor.x === null) springs.anchor.x = anchor;
  if (reducedMotion.matches && dragging) {
    springs.anchor.x = anchor;
    springs.anchor.v = 0;
  } else anchor = springTo(springs.anchor, anchor, dragging ? 2.6 : 3.4, dragging ? 0.62 : 0.9);
  const velocity = springs.anchor.v; // screen widths per second
  springTo(springs.hair, carrying || dragging ? THREE.MathUtils.clamp(-velocity * 0.28 + carryPose.velocity * 0.002, -0.055, 0.055) : 0, 1.6, 0.48);
  springTo(springs.skirt, dragging ? THREE.MathUtils.clamp(-velocity * 0.22, -0.045, 0.045) : 0, 2.2, 0.52);
  state.model.position.x = screenAnchorToWorld(anchor);
  state.currentAnchor = anchor;
  state.behavior = reducedMotion.matches
    ? 'idle-reduced'
    : reaction ? `interactive-${reaction.type}` : behavior.name;

  const behaviorName = reaction?.type || behavior.name;
  const walkingBehavior = behaviorName === 'walk' || behaviorName === 'move';
  const destinationAnchor = behavior.toAnchor ?? POSITION_ANCHORS[behavior.to] ?? anchor;
  const gaitDisabled = reducedMotion.matches || dragging || carrying;
  if (gaitDisabled) walking?.reset();
  const gaitPose = gaitDisabled
    ? { active: false, weight: 0, direction: 1, turn: 0, stride: 0 }
    : walking?.update({
      walking: walkingBehavior,
      rootX: state.model.position.x,
      destinationX: screenAnchorToWorld(destinationAnchor),
      delta: springDelta
    }) ?? { active: false, weight: 0, direction: 1, turn: 0, stride: 0 };

  if (!reducedMotion.matches) {
    applyBasePose(elapsed);
    // Lean into the motion while being carried, with the skirt trailing behind.
    const lean = THREE.MathUtils.clamp(velocity * 0.35, -0.16, 0.16);
    rotateBone('上半身', 0, 0, -lean);
    rotateBone('下半身', 0, 0, lean * 0.4);
    if (carrying) {
      applyCarryPose(carryPose, elapsed);
      applyCarryStyle(carryPose, elapsed);
    }
  }
  else {
    rotateBone('左腕', 0.03, 0, -0.50);
    rotateBone('右腕', -0.03, 0, 0.50);
    rotateBone('左ひじ', 0.04, 0.02, 0.12);
    rotateBone('右ひじ', -0.04, -0.02, -0.12);
    setSmile(0.12);
  }

  if (behaviorName === 'wave') applyWave(behavior.progress, elapsed, behavior.side ?? behavior.variant?.side, behavior.variant);
  if (behaviorName === 'handHold') applyHandHold(behavior.progress, elapsed, behavior.side, behavior.variant);
  if (behaviorName === 'poke') applyPoke(behavior.progress, elapsed, behavior.side, behavior.variant);
  if (behaviorName === 'stretch') applyStretch(behavior.progress, behavior.variant);
  if (behaviorName === 'lookAround') applyLookAround(behavior.progress, behavior.variant);
  if (behaviorName === 'hum') applyHum(behavior.progress, elapsed, behavior.variant);
  if (behaviorName === 'rest-standing' || behaviorName === 'rest') applyRest(behavior.progress);
  if (gaitPose.active) applyWalk(gaitPose);
  applyTurnFollowThrough(gaitPose);
  if (behaviorName === 'headPat' || behaviorName === 'headStroke') applyHeadPat(behavior.progress, behavior.variant);
  if (behaviorName === 'headStroke') rotateBone('頭', 0, 0, Math.sin(elapsed * 3.6) * 0.02 * gestureEnvelope(behavior.progress));
  if (behaviorName === 'hello') applyNod(behavior.progress, true, behavior.variant);

  if (behaviorName !== 'walk' && behaviorName !== 'move') applySkirtTrail(springs.skirt.x);

  normalizeEyeMorphs();
  applyGrantRotations();
  applyHairClearance();
  blendMotionTransition(elapsed);
  if (!gaitDisabled) walking?.solve();
  state.model.updateMatrixWorld(true);
}

function applyCarryStyle(pose, elapsed) {
  // Each pick-up gets its own personality: startled, delighted or embarrassed.
  const airborne = Math.min(1, pose.height / 0.45);
  if (airborne <= 0.01 || pose.phase === 'landing') return;
  // Legs dangle: thighs drift forward, knees bend, toes point down, and the two legs
  // kick out of step with a little sideways swing so it reads even from the front.
  const legSwing = Math.sin(elapsed * 4.6);
  const pendulum = Math.sin(elapsed * 2.3 + 0.6);
  for (const [index, side] of ['左', '右'].entries()) {
    const phase = index === 0 ? legSwing : -legSwing;
    const outward = index === 0 ? 1 : -1;
    rotateBone(`${side}足`, (-0.22 - 0.12 * phase) * airborne, 0, outward * (0.05 + 0.04 * pendulum) * airborne);
    rotateBone(`${side}ひざ`, (0.5 + Math.max(0, phase) * 0.3) * airborne, 0, 0);
    rotateBone(`${side}足首`, 0.32 * airborne, 0, 0);
  }
  rotateBone('下半身', 0, 0, 0.05 * pendulum * airborne);
  applySkirtFollow(-0.18 * airborne, -0.18 * airborne);
  switch (state.carryStyle) {
    case 'wheee': {
      const bounce = Math.sin(elapsed * 6) * 0.08;
      rotateBone('左腕', 0, -0.1 * airborne, (1.15 + bounce) * airborne);
      rotateBone('右腕', 0, 0.1 * airborne, -(1.15 - bounce) * airborne);
      rotateBone('左ひじ', 0, 0, 0.25 * airborne);
      rotateBone('右ひじ', 0, 0, -0.25 * airborne);
      setMorph('びっくり', 0);
      setMorph('笑い', 0.5 * airborne);
      setSmile(0.85 * airborne);
      break;
    }
    case 'shy':
      rotateBone('左腕', 0.2 * airborne, 0.25 * airborne, 0.15 * airborne);
      rotateBone('右腕', 0.2 * airborne, -0.25 * airborne, -0.15 * airborne);
      rotateBone('左ひじ', -0.5 * airborne, 0, 0.3 * airborne);
      rotateBone('右ひじ', -0.5 * airborne, 0, -0.3 * airborne);
      rotateBone('頭', 0.1 * airborne, 0, 0);
      setMorph('びっくり', 0);
      setMorph('照れ', 0.9 * airborne);
      setSmile(0.3 * airborne);
      break;
    default: {
      // Startled: arms out for balance, flailing a little.
      const flail = Math.sin(elapsed * 9) * 0.12;
      rotateBone('左腕', 0, -0.15 * airborne, (0.55 + flail) * airborne);
      rotateBone('右腕', 0, 0.15 * airborne, -(0.55 - flail) * airborne);
      rotateBone('左ひじ', 0, 0, (0.45 - flail) * airborne);
      rotateBone('右ひじ', 0, 0, -(0.45 + flail) * airborne);
      rotateBone('左手首', 0, 0, 0.2 * airborne);
      rotateBone('右手首', 0, 0, -0.2 * airborne);
      setMorph('びっくり', 0.6 * airborne);
    }
  }
}

function applyCarryPose(pose, elapsed) {
  const airborne = Math.min(1, pose.height / 0.45);
  const compression = pose.compression ?? 0;
  const sway = (Math.sin(elapsed * 3.4) * 0.022 + pose.sway * 0.025) * airborne;
  rotateBone('上半身', 0.14 * compression, 0, sway);
  rotateBone('頭', 0.035 * airborne - 0.06 * compression, 0, -sway * 0.5);
  for (const side of ['左', '右']) {
    const kick = pose.phase === 'held' ? Math.sin(elapsed * 3.8 + (side === '右' ? Math.PI : 0)) * 0.05 * airborne : 0;
    rotateBone(`${side}足`, -0.04 * airborne - 0.28 * compression + kick, 0, 0);
    rotateBone(`${side}ひざ`, 0.08 * airborne + 0.56 * compression + Math.max(0, -kick) * 1.5, 0, 0);
    rotateBone(`${side}足首`, -0.04 * airborne - 0.28 * compression - kick * 0.5, 0, 0);
  }
  rotateBone('左腕', 0, 0, -0.12 * airborne - 0.08 * compression);
  rotateBone('右腕', 0, 0, 0.12 * airborne + 0.08 * compression);
  applySkirtFollow(-0.04 * airborne - 0.28 * compression, -0.04 * airborne - 0.28 * compression);
  setMorph('びっくり', (pose.phase === 'falling' ? 0.35 : 0.22) * airborne);
  if (compression > 0) setMorph('まばたき', Math.max(blinkAmount(elapsed), compression * 0.55));
  setSmile(0.18);
}

function applyLighting(weights, env) {
  const intensityScale = state.model?.geometry.userData.MMD?.format === 'pmx' ? 0.65 : 1;
  mixColor(hemisphereLight.color, weights, 'sky');
  mixColor(hemisphereLight.groundColor, weights, 'ground');
  mixColor(directionalLight.color, weights, 'key');
  mixColor(fillLight.color, weights, 'fill');
  // Same sky, weather and scene colour cast as the background.
  for (const light of [hemisphereLight, directionalLight, fillLight]) {
    light.color.setRGB(light.color.r * env.tint[0], light.color.g * env.tint[1], light.color.b * env.tint[2], THREE.LinearSRGBColorSpace);
  }
  hemisphereLight.groundColor.setRGB(
    hemisphereLight.groundColor.r * env.tint[0],
    hemisphereLight.groundColor.g * env.tint[1],
    hemisphereLight.groundColor.b * env.tint[2],
    THREE.LinearSRGBColorSpace
  );
  const flash = env.flash;
  hemisphereLight.intensity = (mixNumber(weights, 'ambientIntensity') * env.ambientScale + flash * 1.6) * intensityScale;
  directionalLight.intensity = (mixNumber(weights, 'keyIntensity') * env.keyScale + flash * 1.4) * intensityScale;
  fillLight.intensity = mixNumber(weights, 'fillIntensity') * env.fillScale * intensityScale;
  if (flash > 0) directionalLight.color.lerp(lightningColor, Math.min(1, flash));
  directionalLight.position.set(env.keyDirection.x, env.keyDirection.y, env.keyDirection.z);
  rimLight.color.setRGB(env.rimColor[0], env.rimColor[1], env.rimColor[2], THREE.LinearSRGBColorSpace);
  rimLight.intensity = env.rimStrength * 0.95 * intensityScale;
  rimLight.position.set(-env.keyDirection.x * 0.6, 12, -18);

  // Grade the materials' built-in ambient with the same time of day / weather / scene light.
  const level = (weights.day + weights.dusk * 0.8 + weights.night * 0.58) * env.ambientScale + flash * 0.45;
  const periodTint = [0, 1, 2].map(index => (
    weights.day + EMISSIVE_DUSK[index] * weights.dusk + EMISSIVE_NIGHT[index] * weights.night
  ));
  for (const material of state.materials || []) {
    const base = material.userData.mikuBaseEmissive;
    material.emissive.setRGB(
      base.r * level * periodTint[0] * env.tint[0],
      base.g * level * periodTint[1] * env.tint[1],
      base.b * level * periodTint[2] * env.tint[2]
    );
  }
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
    state.materials = [];
    state.model.traverse(object => {
      if (object.isMesh) {
        object.castShadow = true;
        object.frustumCulled = false;
        for (const material of [object.material].flat()) {
          const ink = material?.userData?.outlineParameters;
          if (ink && ink.thickness && !ink.mikuScaled) {
            ink.thickness *= 1.5;
            ink.mikuScaled = true;
          }
          if (material?.emissive && !material.userData.mikuBaseEmissive) {
            // MMD materials carry their own ambient (as emissive), which ignores scene lights.
            material.userData.mikuBaseEmissive = material.emissive.clone();
            state.materials.push(material);
          }
        }
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
    walking = createWalking({ model: state.model, bones: state.bones, restPose: state.restPose });
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
  if (ambient) {
    ambient.update(timestamp, {
      hour,
      periodWeights: background.periodWeights,
      sceneWeights: background.sceneWeights,
      weather: state.weather,
      sunrise: state.sunrise,
      sunset: state.sunset
    });
  }
  if (showsCharacter && state.ready) {
    const env = characterEnvironment({
      hour,
      periodWeights: background.periodWeights,
      sceneWeights: background.sceneWeights,
      weather: state.weather,
      nowMs: Date.now(),
      sunrise: state.sunrise,
      sunset: state.sunset
    });
    applyLighting(background.periodWeights, env);
    updateModel(elapsed);
    grounding.update(
      camera.position.y + CAMERA_HEIGHT * (0.5 - GROUND_SCREEN_Y),
      mixNumber(background.periodWeights, 'shadowOpacity') * 1.5 * env.shadowScale,
      carryPose.height
    );
    (outline || renderer).render(scene, camera);
    updateCharacterBounds(timestamp);
  }
  state.renderedAt = timestamp;
}

function sceneIsCrossfading(elapsed) {
  return Object.values(sceneWeightsAt(elapsed)).some(weight => weight > 0.001 && weight < 0.999);
}

function frameInterval() {
  if (reducedMotion.matches) return 1000;
  // The background is mostly static images; only animate smoothly while scenes crossfade.
  if (!showsCharacter) {
    const crossfade = sceneIsCrossfading(currentElapsed()) ? 1000 / FPS_CAP : BACKGROUND_IDLE_INTERVAL;
    return Math.min(crossfade, ambient ? ambient.desiredInterval() : BACKGROUND_IDLE_INTERVAL);
  }
  return 1000 / FPS_CAP;
}

function frame(timestamp) {
  const interval = frameInterval();
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

function contextLine() {
  const lines = CONTEXT_PHRASES[state.language] || CONTEXT_PHRASES['zh-Hant'];
  const hour = currentHour();
  const weather = state.weather?.kind;
  if (weather && weather !== 'clear' && weather !== 'cloudy' && lines[weather]) return variety.line(`context-${weather}`, lines[weather]);
  if (hour >= 5 && hour < 10) return variety.line('context-morning', lines.morning);
  if (hour >= 22 || hour < 4) return variety.line('context-night', lines.night);
  return null;
}

function showTouchPhrase(type) {
  const elapsed = currentElapsed();
  if (state.thinking || speechBubble.classList.contains('visible') || elapsed < state.nextTouchSpeech) return;
  const language = TOUCH_PHRASES[state.language] ? state.language : 'zh-Hant';
  const teased = variety.mood(elapsed) > 0.6 && type !== 'carry';
  const key = teased ? 'teased' : type;
  const phrases = TOUCH_PHRASES[language][key];
  if (!phrases?.length) return;
  state.nextTouchSpeech = elapsed + variety.range(2.5, 5);
  const context = !teased && variety.chance(0.2) ? contextLine() : null;
  showBubble(context || variety.line(`${language}-${key}`, phrases), teased ? 'curious' : 'happy', 2600);
}

function handlePointerDown(event) {
  if (!showsCharacter || !state.interactive || event.button !== 0) return;
  const result = raycastCharacter(event.clientX, event.clientY);
  if (!result || result.zone === 'none') return;
  const point = normalizedPointer(event);
  touchGestures.reset();
  const cheek = result.zone === 'head' && result.normalizedHeight < 0.88 && result.lateral < 0.13;
  state.pointer = {
    id: event.pointerId,
    startX: event.clientX,
    startY: event.clientY,
    startPointX: point.x,
    startWorldY: -point.y * CAMERA_HEIGHT,
    startAnchor: state.currentAnchor,
    started: currentElapsed(),
    side: result.side,
    cheek,
    zone: result.zone,
    variant: result.zone === 'hand' ? chooseVariant('handHold') : null,
    dragging: false
  };
  canvas.setPointerCapture?.(event.pointerId);
  postNative({ type: 'drag', active: true });
  // Squash and recoil where she was touched.
  kick(springs.bob, -0.9);
  const facePoint = projectedFaceAnchor();
  kick(springs.jolt, (facePoint && point.x < facePoint.x ? -1 : 1) * (result.zone === 'head' ? 1.1 : 0.6));
  postNative({ type: 'haptic' });

  const touch = { ...point, touch: true, side: result.side };
  if (cheek) state.reaction = null;
  else if (result.zone === 'head') startReaction('headPat', touch);
  else if (result.zone === 'hand') state.reaction = null;
  else startReaction('hello', touch);

  if (!hasNativeBridge() && !cheek && result.zone !== 'hand' && !state.thinking && !speechBubble.classList.contains('visible')) {
    const [text, alternate] = browserReactionText(result.zone);
    showBubble(Math.random() > 0.5 ? text : alternate, result.zone === 'head' ? 'happy' : 'curious', 2600);
  }
}

function handlePointerMove(event) {
  if (!state.interactive) return;
  const point = normalizedPointer(event);
  const elapsed = currentElapsed();
  if (state.pointer?.id === event.pointerId) {
    moveGrabbedPointer(state.pointer, event, elapsed);
    if (reducedMotion.matches) renderState(performance.now());
  }

  const now = performance.now();
  if (now - state.lastLookPointerTime < 50) return;
  state.lastLookPointerTime = now;
  if (!hasNativeBridge() && !state.pointer) {
    updateHover(raycastCharacter(event.clientX, event.clientY), point.x, point.y);
  }
  const bounds = state.bounds;
  if (bounds
    && point.x >= bounds.x && point.x <= bounds.x + bounds.width
    && point.y >= bounds.y && point.y <= bounds.y + bounds.height) {
    state.lookTarget = { x: point.x, y: point.y, until: elapsed + 0.8 };
  }
}

function rubHead(pointer, point, elapsed) {
  // Pressing on her head and moving side to side is petting, not picking her up.
  state.lookTarget = { x: point.x, y: point.y, until: elapsed + 0.6 };
  if (elapsed - (pointer.lastRubNote ?? -Infinity) > 0.35) {
    spawnHoverNote(point.x, point.y, 'head');
    pointer.lastRubNote = elapsed;
  }
  const stroke = reducedMotion.matches ? null : rubGestures.sample({ zone: 'head', x: point.x, y: point.y, time: elapsed });
  if (stroke) {
    startReaction('headStroke', { x: point.x, y: point.y, touch: true });
    showTouchPhrase('headStroke');
    postNative({ type: 'hover-haptic' });
  }
}

function moveGrabbedPointer(pointer, event, elapsed) {
  const distance = Math.hypot(event.clientX - pointer.startX, event.clientY - pointer.startY);
  if (pointer.zone === 'head' && !pointer.cheek && !pointer.dragging) {
    const dx = Math.abs(event.clientX - pointer.startX);
    const dy = Math.abs(event.clientY - pointer.startY);
    if (pointer.rubbing || (dx > 10 && dx > dy * 1.3)) {
      if (!pointer.rubbing) rubGestures.reset();
      pointer.rubbing = true;
      rubHead(pointer, normalizedPointer(event), elapsed);
      return;
    }
    // Wait until it's clear whether this is a rub (sideways) or a lift (mostly vertical).
    if (distance <= 18) return;
  }
  if (!pointer.dragging && distance <= 7) return;
  const point = normalizedPointer(event);
  if (!pointer.dragging) {
    pointer.dragging = true;
    endHover();
    if (!reducedMotion.matches) carry.begin({ pointerY: pointer.startWorldY, time: elapsed });
    state.carryStyle = chooseVariant('carry').style;
    variety.noteTouch(elapsed);
    if (variety.chance(0.55)) showTouchPhrase('carry');
  }
  state.reaction = null;
  holdAnchor(pointer.startAnchor + point.x - pointer.startPointX, elapsed, 15);
  if (!reducedMotion.matches) carry.move({ pointerY: -point.y * CAMERA_HEIGHT, time: elapsed });
}

function finishPointer(event = null, { reset = false } = {}) {
  const pointer = state.pointer;
  if (!pointer || (event && pointer.id !== event.pointerId)) return;
  if (event?.type === 'pointerup') moveGrabbedPointer(pointer, event, currentElapsed());
  state.pointer = null;
  if (canvas.hasPointerCapture?.(pointer.id)) canvas.releasePointerCapture?.(pointer.id);
  postNative({ type: 'drag', active: false });
  if (pointer.dragging) {
    // Remember where she was dropped.
    const anchor = state.anchorHold?.anchor ?? state.currentAnchor;
    state.pinnedAnchor = THREE.MathUtils.clamp(anchor, 0.16, 0.68);
    state.anchorHold = null;
    postNative({ type: 'pin', x: state.pinnedAnchor });
  } else if (event?.type === 'pointerup' && pointer.cheek) {
    startReaction('poke', { touch: true, side: pointer.side });
    showTouchPhrase('poke');
  } else if (event?.type === 'pointerup' && pointer.zone === 'hand') {
    startReaction('wave', { touch: true, side: pointer.side });
  }
  if (reset || reducedMotion.matches) carry.reset();
  else carry.release({ time: currentElapsed() });
}

function spawnHoverNote(x, y, zone) {
  if (reducedMotion.matches || !showsCharacter) return;
  const note = document.createElement('span');
  note.className = `hover-note zone-${zone}`;
  note.textContent = HOVER_NOTE_SYMBOLS[Math.floor(Math.random() * HOVER_NOTE_SYMBOLS.length)];
  note.style.left = `${x * 100}%`;
  note.style.top = `${y * 100}%`;
  note.style.setProperty('--drift', `${(Math.random() - 0.5) * 46}px`);
  note.style.setProperty('--spin', `${(Math.random() - 0.5) * 40}deg`);
  note.addEventListener('animationend', () => note.remove(), { once: true });
  document.body.appendChild(note);
}

function pickPhrase(zone) {
  const language = HOVER_PHRASES[state.language] ? state.language : 'zh-Hant';
  const phrases = HOVER_PHRASES[language][zone] || [];
  const context = variety.chance(0.3) ? contextLine() : null;
  return context || variety.line(`${language}-hover-${zone}`, phrases) || '';
}

/** Called for every pointer position over (or near) Miku; drives the hover reaction. */
function updateHover(hit, x, y) {
  const elapsed = currentElapsed();
  if (!hit) {
    if (state.hover) endHover();
    return;
  }
  if (state.pointer || carry.status().phase !== 'idle') {
    touchGestures.reset();
    return;
  }
  const stroke = reducedMotion.matches ? null : touchGestures.sample({ zone: hit.zone, x, y, time: elapsed });
  if (stroke) {
    startReaction('headStroke', { x, y, touch: true });
    showTouchPhrase('headStroke');
    spawnHoverNote(x, y, 'head');
    postNative({ type: 'hover-haptic' });
  }
  const faceX = projectedFaceAnchor()?.x ?? x;
  const side = x >= faceX ? 1 : -1;
  if (!state.hover) {
    state.hover = { zone: hit.zone, since: elapsed, lastNote: elapsed, dwellDone: false, side };
    document.body.classList.add('miku-hover');
    spawnHoverNote(x, y, hit.zone);
    // A little "oh!" bounce when she notices the cursor.
    kick(springs.bob, 0.55);
    kick(springs.jolt, side * 0.5);
    if (elapsed >= state.nextHoverHaptic) {
      postNative({ type: 'hover-haptic' });
      state.nextHoverHaptic = elapsed + 1.2;
    }
  } else {
    state.hover.zone = hit.zone;
    state.hover.side = side;
    if (elapsed - state.hover.lastNote > 0.55) {
      spawnHoverNote(x, y, hit.zone);
      state.hover.lastNote = elapsed;
    }
  }
  document.body.dataset.hoverZone = hit.zone;
  state.lookTarget = { x, y, until: elapsed + 0.6 };

  // Rest the cursor on her for a moment and she says hello back.
  if (!state.hover.dwellDone && elapsed - state.hover.since > HOVER_DWELL_SECONDS && !state.pointer) {
    state.hover.dwellDone = true;
    if (!state.reaction && !reducedMotion.matches) startReaction('hello');
    const bubbleBusy = state.thinking || speechBubble.classList.contains('visible');
    if (!bubbleBusy && elapsed >= state.nextHoverGreeting) {
      state.nextHoverGreeting = elapsed + HOVER_GREETING_COOLDOWN;
      showBubble(pickPhrase(hit.zone), hit.zone === 'head' ? 'happy' : 'curious', 2600);
    }
  }
}

function endHover() {
  state.hover = null;
  touchGestures.reset();
  document.body.classList.remove('miku-hover');
  delete document.body.dataset.hoverZone;
}

function hitTest(x, y) {
  if (!showsCharacter || !state.interactive || !state.model) return false;
  if (state.pointer) return true;
  const nx = Number(x);
  const ny = Number(y);
  if (!Number.isFinite(nx) || !Number.isFinite(ny)) return false;
  const rect = canvas.getBoundingClientRect();
  const hit = raycastCharacter(rect.left + nx * rect.width, rect.top + ny * rect.height);
  updateHover(hit, nx, ny);
  return hit ? hit.zone : false;
}

canvas.addEventListener('webglcontextlost', event => {
  event.preventDefault();
  finishPointer(null, { reset: true });
  carry.reset();
  stopLoop();
  state.error = 'WebGL context lost';
}, false);
canvas.addEventListener('webglcontextrestored', () => window.location.reload(), false);

canvas.addEventListener('pointerdown', handlePointerDown);
canvas.addEventListener('pointermove', handlePointerMove, { passive: true });
canvas.addEventListener('pointerup', event => finishPointer(event));
canvas.addEventListener('pointerleave', () => { if (!state.pointer) endHover(); });
canvas.addEventListener('pointercancel', event => finishPointer(event));
canvas.addEventListener('lostpointercapture', event => finishPointer(event));

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
    pinnedAnchor: state.pinnedAnchor,
    sceneSlotSeconds: state.sceneSlotSeconds,
    thinking: state.thinking,
    weather: { ...state.weather },
    sunrise: state.sunrise,
    sunset: state.sunset,
    ambientEnabled: state.ambientEnabled,
    hover: state.hover ? state.hover.zone : null,
    grounding: grounding?.status() ?? null,
    carry: carry.status(),
    walking: walking?.status() ?? null,
    turnYaw: turning.yaw.x,
    turnSpin: turning.yaw.v,
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
    if (!state.interactive) endHover();
    if (!state.interactive && state.pointer) {
      finishPointer(null, { reset: true });
    }
    if (!state.interactive) carry.reset();
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
    else if (!state.reaction?.touch) state.reaction = null;
    renderState(performance.now());
    return status();
  },
  hitTest,
  endHover() {
    endHover();
    return true;
  },
  setLanguage(language) {
    state.language = HOVER_PHRASES[language] ? language : 'zh-Hant';
    return true;
  },
  setThinking(thinking) {
    setThinking(thinking);
    return true;
  },
  setPinnedAnchor(anchor = null) {
    const value = anchor === null ? null : Number(anchor);
    state.pinnedAnchor = value === null || !Number.isFinite(value) ? null : THREE.MathUtils.clamp(value, 0.16, 0.68);
    state.anchorHold = null;
    renderState(performance.now());
    return status();
  },
  setWeather(weather = {}) {
    state.weather = normalizeWeather(weather);
    renderState(performance.now());
    return status();
  },
  setSunTimes(sunrise, sunset) {
    const rise = Number(sunrise);
    const set = Number(sunset);
    if (!Number.isFinite(rise) || !Number.isFinite(set) || set <= rise) return false;
    state.sunrise = rise;
    state.sunset = set;
    TIME_ANCHORS = timeAnchors(rise, set);
    renderState(performance.now());
    return status();
  },
  setAmbientEnabled(enabled) {
    state.ambientEnabled = Boolean(enabled);
    ambient?.setEnabled(state.ambientEnabled);
    renderState(performance.now());
    return status();
  },
  setRotationInterval(seconds) {
    const value = Number(seconds);
    if (!Number.isFinite(value) || value < 30) return false;
    state.sceneSlotSeconds = value;
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
  touchGestures.reset();
  finishPointer(null, { reset: true });
  carry.reset();
  resize();
  walking?.reset();
  ambient?.resize();
  renderState(performance.now());
}, { passive: true });

document.addEventListener('visibilitychange', () => {
  if (document.hidden) {
    endHover();
    finishPointer(null, { reset: true });
    carry.reset();
    stopLoop();
  }
  else {
    renderState(performance.now());
    startLoop();
  }
}, { passive: true });

window.addEventListener('focus', () => renderState(performance.now()), { passive: true });
window.addEventListener('blur', () => {
  finishPointer();
  endHover();
});
reducedMotion.addEventListener('change', () => {
  touchGestures.reset();
  renderState(performance.now());
});

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
