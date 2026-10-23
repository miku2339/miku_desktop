import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

import { createRelationship } from '../Wallpaper/companion/relationship.js';

const companionSource = readFileSync(
  new URL('../Wallpaper/companion/companion.js', import.meta.url),
  'utf8'
);

function sourceSection(startMarker, endMarker) {
  const start = companionSource.indexOf(startMarker);
  const end = companionSource.indexOf(endMarker, start);
  if (start < 0 || end < 0) throw new Error(`Missing companion.js section: ${startMarker}`);
  return companionSource.slice(start, end);
}

const allowlistsSource = sourceSection('const ALLOWED_EMOTIONS', 'const CONTROLLED_BONES');
const talkingSource = sourceSection('const MOUTH_VOWELS', '// How she feels');
const companionAPISource = sourceSection(
  'window.mikuCompanion = Object.freeze({',
  "\n\ndocument.body.classList.toggle('interaction-enabled'"
);

class FakeClassList {
  constructor() {
    this.values = new Set();
  }

  add(...names) {
    for (const name of names) this.values.add(name);
  }

  remove(...names) {
    for (const name of names) this.values.delete(name);
  }

  contains(name) {
    return this.values.has(name);
  }

  toggle(name, force) {
    if (force ?? !this.values.has(name)) this.values.add(name);
    else this.values.delete(name);
  }
}

function createHarness({ reduced = false } = {}) {
  let elapsed = 0;
  let nextTimer = 1;
  const reactionCalls = [];
  const vowelNames = ['あ', 'い', 'う', 'え', 'お'];
  const influences = vowelNames.map(() => 0);
  const state = {
    activeElapsed: 0,
    anchorHold: null,
    bubbleTimer: null,
    currentAnchor: 0.43,
    emotion: 'calm',
    forcedScene: null,
    interactive: true,
    loadedScenes: ['shibuya'],
    model: { morphTargetInfluences: influences },
    morphs: Object.fromEntries(vowelNames.map((name, index) => [name, index])),
    pinnedAnchor: null,
    pointer: null,
    previewElapsed: null,
    reaction: null,
    ready: true,
    sceneSlotSeconds: 300,
    sunrise: 6,
    sunset: 18,
    talk: null,
    thinking: false,
    upset: { x: 0, v: 0, side: 1 }
  };
  const reducedMotion = { matches: reduced };
  const speechBubble = {
    classList: new FakeClassList(),
    dataset: {}
  };
  const bubbleText = { textContent: '' };
  const relationship = createRelationship();

  const context = vm.createContext({
    THREE: {
      MathUtils: {
        clamp: (value, minimum, maximum) => Math.min(maximum, Math.max(minimum, value))
      }
    },
    bubbleText,
    carry: { reset() {} },
    chooseVariant: () => ({ flip: 1 }),
    clearTimeout() {},
    document: { body: { classList: new FakeClassList() } },
    endHover() {},
    finishPointer() {},
    hitTest() {},
    HOVER_PHRASES: { 'zh-Hant': {} },
    normalizeHour: value => value,
    performance: { now: () => elapsed * 1000 },
    reducedMotion,
    relationship,
    renderState() {},
    resetMorphs: () => influences.fill(0),
    showsCharacter: true,
    speechBubble,
    state,
    status: () => ({
      emotion: state.emotion,
      reaction: state.reaction?.type ?? null
    }),
    updateCharacterBounds() {},
    variety: { chance: () => false },
    window: {
      mikuCompanion: null,
      setTimeout: () => nextTimer++
    }
  });

  context.currentElapsed = () => elapsed;
  context.startReaction = (type, options = {}) => {
    reactionCalls.push({ type, options });
    state.reaction = {
      type,
      touch: Boolean(options.touch),
      variant: options.variant ?? null
    };
    return true;
  };

  vm.runInContext(allowlistsSource, context, { filename: 'companion.js#allowlists' });
  vm.runInContext(
    `${talkingSource}\nglobalThis.__talking = { startTalking, applyTalking, setThinking };`,
    context,
    { filename: 'companion.js#talking' }
  );
  vm.runInContext(companionAPISource, context, { filename: 'companion.js#api' });

  return {
    api: context.window.mikuCompanion,
    bubbleText,
    influences,
    reactionCalls,
    reducedMotion,
    setElapsed(value) {
      elapsed = value;
      state.activeElapsed = value;
    },
    speechBubble,
    state,
    talking: context.__talking
  };
}

function mouthIsClosed(influences) {
  return influences.every(value => value === 0);
}

test('reduced motion prevents talking morphs from starting', () => {
  const harness = createHarness({ reduced: true });
  harness.talking.startTalking('這是一段測試文字');
  harness.setElapsed(0.2);
  harness.talking.applyTalking(0.2);

  assert.equal(mouthIsClosed(harness.influences), true);
  assert.equal(harness.state.talk, null);
});

test('enabling reduced motion during a reply stops further talking morphs', () => {
  const harness = createHarness();
  harness.talking.startTalking('這是一段測試文字');
  harness.setElapsed(0.1);
  harness.talking.applyTalking(0.1);
  assert.equal(mouthIsClosed(harness.influences), false);

  harness.influences.fill(0);
  harness.reducedMotion.matches = true;
  harness.setElapsed(0.2);
  harness.talking.applyTalking(0.2);

  assert.equal(mouthIsClosed(harness.influences), true);
  assert.equal(harness.state.talk, null);
});

test('a failed request cannot resume the previous reply mouth movement', () => {
  const harness = createHarness();
  harness.talking.startTalking('這是一段足夠長、仍未說完的回覆文字');
  harness.setElapsed(0.05);
  harness.talking.setThinking(true);
  harness.setElapsed(0.1);
  harness.talking.setThinking(false);
  harness.influences.fill(0);
  harness.setElapsed(0.2);
  harness.talking.applyTalking(0.2);

  assert.equal(harness.speechBubble.classList.contains('visible'), false);
  assert.equal(mouthIsClosed(harness.influences), true);
  assert.equal(harness.state.talk, null);
});

test('resetting memory clears reply reaction, emotion, bubble and mouth state', () => {
  const harness = createHarness();
  harness.api.receiveReply({ emotion: 'pout', action: 'pout', text: '哼哼哼' });
  harness.setElapsed(0.2);
  harness.talking.applyTalking(0.2);

  harness.api.setRelationship({
    reset: true,
    friendship: 30,
    offended: false,
    strikesToday: 0
  });

  assert.deepEqual(
    {
      bubbleVisible: harness.speechBubble.classList.contains('visible'),
      emotion: harness.state.emotion,
      mouthClosed: mouthIsClosed(harness.influences),
      reaction: harness.state.reaction?.type ?? null,
      talk: harness.state.talk,
      thinking: harness.state.thinking
    },
    {
      bubbleVisible: false,
      emotion: 'calm',
      mouthClosed: true,
      reaction: null,
      talk: null,
      thinking: false
    }
  );
});

test('ordinary relationship sync keeps the current reply speaking', () => {
  const harness = createHarness();
  harness.api.receiveReply({ emotion: 'happy', action: 'idle', text: '很高興見到你！' });
  const activeTalk = harness.state.talk;

  harness.api.setRelationship({
    reset: false,
    friendship: 45,
    offended: false,
    strikesToday: 0
  });

  assert.equal(harness.state.talk, activeTalk);
  assert.equal(harness.speechBubble.classList.contains('visible'), true);
  assert.equal(harness.state.emotion, 'happy');
});

test('every supported reply action routes to its intended reaction', () => {
  const routes = new Map([
    ['wave', 'wave'],
    ['nod', 'hello'],
    ['bow', 'bow'],
    ['shakeHead', 'shakeHead'],
    ['laugh', 'laugh'],
    ['clap', 'clap'],
    ['cheer', 'cheer'],
    ['shy', 'shy'],
    ['sad', 'sad'],
    ['pout', 'pout'],
    ['surprised', 'surprised'],
    ['think', 'think'],
    ['dance', 'dance'],
    ['idolPose', 'idolPose'],
    ['yawn', 'yawn'],
    ['stretch', 'stretch'],
    ['rest', 'rest'],
    ['idle', null]
  ]);

  for (const [action, expectedReaction] of routes) {
    const harness = createHarness();
    harness.api.receiveReply({ emotion: 'calm', action, text: '好。' });
    assert.equal(
      harness.state.reaction?.type ?? null,
      expectedReaction,
      `${action} should route to ${expectedReaction ?? 'no reaction'}`
    );
  }
});

test('she waves once for hello, then nods instead of waving again and again', () => {
  const harness = createHarness();
  harness.setElapsed(10);
  harness.api.receiveReply({ emotion: 'happy', action: 'wave', text: '嗨！' });
  assert.equal(harness.state.reaction?.type, 'wave');
  harness.setElapsed(40);
  harness.api.receiveReply({ emotion: 'happy', action: 'wave', text: '對呀！' });
  assert.equal(harness.state.reaction?.type, 'hello', 'a second wave half a minute later is a nod');
  harness.setElapsed(10 + 151);
  harness.api.receiveReply({ emotion: 'happy', action: 'wave', text: '掰掰～' });
  assert.equal(harness.state.reaction?.type, 'wave', 'a while later she can wave again');
});

test('offended cheerful replies do not replace an active touch reaction', () => {
  for (const action of ['clap', 'laugh', 'dance', 'shy']) {
    const harness = createHarness();
    harness.api.setRelationship({ friendship: 30, offended: true, strikesToday: 1 });
    const touchReaction = { type: 'headPat', touch: true, variant: null };
    harness.state.reaction = touchReaction;

    harness.api.receiveReply({ emotion: 'happy', action, text: '好。' });

    assert.equal(harness.state.reaction, touchReaction, `${action} replaced the touch reaction`);
    assert.equal(harness.reactionCalls.length, 0, `${action} started while offended`);
  }
});

test('reply gestures never open a second line of dialogue', () => {
  const gestures = [
    'bow', 'shakeHead', 'laugh', 'clap', 'cheer', 'shy', 'sad', 'pout',
    'surprised', 'think', 'dance', 'idolPose', 'yawn'
  ];

  for (const action of gestures) {
    const harness = createHarness();
    harness.api.receiveReply({ emotion: 'calm', action, text: '好。' });
    assert.equal(harness.state.reaction?.variant?.talk, false, `${action} may speak over the reply`);
  }
});
