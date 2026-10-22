import assert from 'node:assert/strict';
import fs from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const companionSource = fs.readFileSync(new URL('../Wallpaper/companion/companion.js', import.meta.url), 'utf8');

function sourceFor(name) {
  const start = companionSource.indexOf(`function ${name}(`);
  assert.notEqual(start, -1, `${name} must exist`);
  const body = companionSource.indexOf(') {', start) + 2;
  let depth = 0;
  for (let index = body; index < companionSource.length; index += 1) {
    if (companionSource[index] === '{') depth += 1;
    else if (companionSource[index] === '}') depth -= 1;
    if (depth === 0) return companionSource.slice(start, index + 1);
  }
  throw new Error(`Could not extract ${name}`);
}

function harness({ offended = false, scene = 'shibuya' } = {}) {
  const calls = { carryBegin: 0, carryMove: 0, pin: [], reactions: [] };
  const context = vm.createContext({
    THREE: { MathUtils: { clamp: (value, minimum, maximum) => Math.min(maximum, Math.max(minimum, value)) } },
    state: {
      activeScene: scene,
      currentAnchor: 0.3,
      anchorHold: null,
      pinnedAnchor: null,
      pointer: null,
      reaction: null,
      lookTarget: null,
      pendingShake: null,
      lastImpact: 0,
      carryStyle: null
    },
    roomGeometry: { clearForeground: [0.05, 0.64, 0.36, 0.34] },
    relationship: { offended, level: 1, snubs: () => false },
    reducedMotion: { matches: false },
    normalizedPointer: event => event.point,
    currentElapsed: () => 5,
    holdAnchor: null,
    carry: {
      begin: () => { calls.carryBegin += 1; },
      move: () => { calls.carryMove += 1; },
      release: () => {},
      reset: () => {}
    },
    shake: { begin: () => {}, sample: () => {}, release: () => ({ peak: 0 }) },
    endHover: () => {},
    chooseVariant: () => ({ style: 'plain' }),
    variety: { noteTouch: () => {}, chance: () => false },
    reportTouch: () => {},
    showTouchPhrase: () => {},
    postNative: payload => { if (payload.type === 'pin') calls.pin.push(payload.x); },
    snubTouch: () => {},
    startReaction: type => {
      calls.reactions.push(type);
      context.holdAnchor(context.state.currentAnchor, 5, 12);
    },
    canvas: {
      hasPointerCapture: () => false,
      releasePointerCapture: () => {}
    },
    window: { innerWidth: 1600, innerHeight: 1000 },
    CAMERA_HEIGHT: 29
  });
  vm.runInContext([
    sourceFor('holdAnchor'),
    sourceFor('handLeadingAnchor'),
    sourceFor('moveGrabbedPointer'),
    sourceFor('finishPointer'),
    'globalThis.api = { handLeadingAnchor, moveGrabbedPointer, finishPointer };'
  ].join('\n'), context);
  return { api: context.api, calls, context };
}

function pointer() {
  return {
    id: 1,
    zone: 'hand',
    side: '左',
    startX: 100,
    startY: 100,
    startPointX: 0.3,
    startWorldY: -14.5,
    startAnchor: 0.3,
    started: 0,
    dragging: false,
    greeted: true
  };
}

test('horizontal hand movement leads without starting carry', () => {
  const { api, calls, context } = harness();
  const held = pointer();
  api.moveGrabbedPointer(held, { clientX: 140, clientY: 104, point: { x: 0.4, y: 0.5 } }, 1);
  assert.equal(held.leading, true);
  assert.equal(held.dragging, false);
  assert.equal(calls.carryBegin, 0);
  assert.ok(Math.abs(context.state.anchorHold.anchor - 0.4) < 1e-12);
});

test('a clear upward pull still enters carry', () => {
  const { api, calls } = harness();
  const held = pointer();
  api.moveGrabbedPointer(held, { clientX: 102, clientY: 50, point: { x: 0.31, y: 0.35 } }, 1);
  assert.equal(held.leading, undefined);
  assert.equal(held.dragging, true);
  assert.equal(calls.carryBegin, 1);
  assert.equal(calls.carryMove, 1);
});

test('an offended relationship excludes hand leading', () => {
  const { api, calls } = harness({ offended: true });
  const held = pointer();
  api.moveGrabbedPointer(held, { clientX: 140, clientY: 104, point: { x: 0.4, y: 0.5 } }, 1);
  assert.equal(held.leading, undefined);
  assert.equal(held.dragging, true);
  assert.equal(calls.carryBegin, 1);
});

test('release pins the reached position and discards the unfinished target before waving', () => {
  const { api, calls, context } = harness();
  const held = pointer();
  held.leading = true;
  context.state.pointer = held;
  context.state.currentAnchor = 0.37;
  context.state.anchorHold = { anchor: 0.6, until: 20, releaseEnd: 24 };
  api.finishPointer({
    type: 'pointerup', pointerId: 1, clientX: 220, clientY: 104, point: { x: 0.6, y: 0.5 }
  });
  assert.equal(context.state.pinnedAnchor, 0.37);
  assert.deepEqual(calls.pin, [0.37]);
  assert.deepEqual(calls.reactions, ['wave']);
  assert.equal(context.state.anchorHold.anchor, 0.37, 'wave holds the reached position, not the stale target');
});

test('room leading uses the clear-floor boundary for hold, pin and gait destination', () => {
  const { api, context } = harness({ scene: 'room' });
  const held = pointer();
  api.moveGrabbedPointer(held, { clientX: 500, clientY: 104, point: { x: 0.9, y: 0.5 } }, 1);
  assert.equal(context.state.anchorHold.anchor, 0.41);

  const reaction = { leading: held.leading, toAnchor: context.state.anchorHold.anchor };
  context.state.currentAnchor = 0.41;
  const led = reaction.leading && Math.abs(reaction.toAnchor - context.state.currentAnchor) > 0.012;
  assert.equal(led, false, 'walking stops at the same clamped target the model can reach');
  assert.equal(api.handLeadingAnchor(0.9), 0.41);

  context.state.pointer = held;
  api.finishPointer();
  assert.equal(context.state.pinnedAnchor, 0.41);
});
