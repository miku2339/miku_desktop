import assert from 'node:assert/strict';
import test from 'node:test';

import { createTouchGestures } from '../Wallpaper/companion/touch-gestures.js';

function stroke(gestures, startTime, startX = 0.48) {
  gestures.sample({ zone: 'body', x: startX, y: 0.2, time: startTime });
  const points = [startX, startX + 0.006, startX + 0.013, startX + 0.019, startX + 0.013];
  let interaction = null;
  points.forEach((x, index) => {
    interaction ||= gestures.sample({ zone: 'head', x, y: 0.2, time: startTime + 0.01 + index * 0.05 });
  });
  return interaction;
}

test('a deliberate left-right head stroke emits a bounded interaction', () => {
  const gestures = createTouchGestures();
  const points = [0.48, 0.486, 0.493, 0.499, 0.493, 0.487];
  let interaction = null;

  points.forEach((x, index) => {
    interaction ||= gestures.sample({ zone: 'head', x, y: 0.2, time: index * 0.05 });
  });

  assert.equal(interaction?.type, 'headStroke');
  assert.ok(interaction.intensity > 0 && interaction.intensity <= 1);
});

test('a straight pointer pass over the head does not count as a stroke', () => {
  const gestures = createTouchGestures();
  const results = [0.46, 0.47, 0.48, 0.49, 0.5].map((x, index) => (
    gestures.sample({ zone: 'head', x, y: 0.2, time: index * 0.05 })
  ));

  assert.deepEqual(results, [null, null, null, null, null]);
});

test('sub-threshold pointer jitter does not count as a stroke', () => {
  const gestures = createTouchGestures();
  const results = [0.5, 0.501, 0.499, 0.5015, 0.5].map((x, index) => (
    gestures.sample({ zone: 'head', x, y: 0.2, time: index * 0.05 })
  ));

  assert.deepEqual(results, [null, null, null, null, null]);
});

test('cooldown suppresses an immediate second stroke', () => {
  const gestures = createTouchGestures();

  assert.equal(stroke(gestures, 0)?.type, 'headStroke');
  assert.equal(stroke(gestures, 0.3), null);
  assert.equal(stroke(gestures, 1.05)?.type, 'headStroke');
});

test('continuous natural stroking can emit again after cooldown', () => {
  const gestures = createTouchGestures();
  const emissions = [];
  let x = 0.48;
  let direction = 1;

  for (let index = 0; index < 32; index += 1) {
    const interaction = gestures.sample({ zone: 'head', x, y: 0.2, time: index * 0.05 });
    if (interaction) emissions.push(index * 0.05);
    x += direction * 0.006;
    if (x >= 0.498 || x <= 0.48) direction *= -1;
  }

  assert.ok(emissions.length >= 2);
  assert.ok(emissions[1] - emissions[0] >= 0.8);
});

for (const interruption of [
  { name: 'hand hit', sample: { zone: 'hand', pressed: false } },
  { name: 'body hit', sample: { zone: 'body', pressed: false } },
  { name: 'pressed pointer', sample: { zone: 'head', pressed: true } }
]) {
  test(`${interruption.name} resets a partial head stroke`, () => {
    const gestures = createTouchGestures();
    gestures.sample({ zone: 'head', x: 0.48, y: 0.2, time: 0 });
    gestures.sample({ zone: 'head', x: 0.49, y: 0.2, time: 0.05 });
    gestures.sample({ zone: 'head', x: 0.5, y: 0.2, time: 0.1 });
    gestures.sample({ ...interruption.sample, x: 0.5, y: 0.2, time: 0.15 });

    assert.equal(gestures.sample({ zone: 'head', x: 0.493, y: 0.2, time: 0.2 }), null);
    assert.equal(gestures.sample({ zone: 'head', x: 0.486, y: 0.2, time: 0.25 }), null);
  });
}

test('a stale sample gap cannot complete an earlier partial stroke', () => {
  const gestures = createTouchGestures();
  gestures.sample({ zone: 'head', x: 0.48, y: 0.2, time: 0 });
  gestures.sample({ zone: 'head', x: 0.49, y: 0.2, time: 0.05 });
  gestures.sample({ zone: 'head', x: 0.5, y: 0.2, time: 0.1 });

  assert.equal(gestures.sample({ zone: 'head', x: 0.493, y: 0.2, time: 0.5 }), null);
  assert.equal(gestures.sample({ zone: 'head', x: 0.486, y: 0.2, time: 0.55 }), null);
});

test('invalid and non-monotonic samples reset safely', () => {
  const invalidSamples = [
    { zone: 'head', x: Number.NaN, y: 0.2, time: 0.15 },
    { zone: 'head', x: 0.5, y: 2, time: 0.15 },
    { zone: 'head', x: 0.5, y: 0.2, time: Number.POSITIVE_INFINITY },
    { zone: 'head', x: 0.5, y: 0.2, time: 0.01 }
  ];

  for (const invalid of invalidSamples) {
    const gestures = createTouchGestures();
    gestures.sample({ zone: 'head', x: 0.48, y: 0.2, time: 0.1 });
    gestures.sample({ zone: 'head', x: 0.5, y: 0.2, time: 0.2 });
    assert.doesNotThrow(() => gestures.sample(invalid));
    assert.equal(gestures.sample({ zone: 'head', x: 0.493, y: 0.2, time: 0.25 }), null);
  }

  const gestures = createTouchGestures();
  assert.equal(stroke(gestures, 1)?.type, 'headStroke');
  gestures.reset();
  assert.equal(stroke(gestures, 1.3)?.type, 'headStroke');
});

test('a non-monotonic sample after jitter cannot preserve the old path', () => {
  const gestures = createTouchGestures();
  gestures.sample({ zone: 'head', x: 0.5, y: 0.2, time: 0 });
  gestures.sample({ zone: 'head', x: 0.501, y: 0.2, time: 0.1 });
  gestures.sample({ zone: 'head', x: 0.49, y: 0.2, time: 0.05 });
  gestures.sample({ zone: 'head', x: 0.496, y: 0.2, time: 0.15 });

  assert.equal(gestures.sample({ zone: 'head', x: 0.502, y: 0.2, time: 0.2 }), null);
});

test('large strokes cap intensity at one', () => {
  const gestures = createTouchGestures();
  gestures.sample({ zone: 'head', x: 0.2, y: 0.2, time: 0 });
  gestures.sample({ zone: 'head', x: 0.35, y: 0.2, time: 0.05 });
  const interaction = gestures.sample({ zone: 'head', x: 0.2, y: 0.2, time: 0.1 });

  assert.deepEqual(interaction, { type: 'headStroke', intensity: 1 });
});
