import assert from 'node:assert/strict';
import test from 'node:test';

import { createCarry } from '../Wallpaper/companion/carry.js';

function stepFor(carry, { from, seconds, fps }) {
  const frames = Math.ceil(seconds * fps);
  let result = carry.status();
  for (let frame = 1; frame <= frames; frame += 1) {
    result = carry.update({ time: from + frame / fps });
  }
  return result;
}

test('grab keeps its initial height until the pointer moves and preserves the grab offset', () => {
  const carry = createCarry();

  carry.begin({ pointerY: 12, time: 0 });
  assert.deepEqual(carry.status(), {
    phase: 'held',
    height: 0,
    velocity: 0,
    sway: 0
  });

  carry.update({ time: 0.1 });
  assert.equal(carry.status().height, 0);

  carry.move({ pointerY: 14, time: 0.1 });
  stepFor(carry, { from: 0.1, seconds: 0.6, fps: 60 });
  assert.ok(Math.abs(carry.status().height - 2) < 0.01);

  carry.move({ pointerY: 15, time: 0.7 });
  stepFor(carry, { from: 0.7, seconds: 0.6, fps: 60 });
  assert.ok(Math.abs(carry.status().height - 3) < 0.01);
});

test('lift is capped at the configured maximum height', () => {
  const carry = createCarry({ maxHeight: 2.5 });
  carry.begin({ pointerY: 4, time: 0 });
  carry.move({ pointerY: 100, time: 0 });
  stepFor(carry, { from: 0, seconds: 1, fps: 60 });

  assert.ok(carry.status().height <= 2.5);
  assert.ok(Math.abs(carry.status().height - 2.5) < 0.01);
});

test('release keeps position continuous and a stationary release falls monotonically', () => {
  const carry = createCarry();
  carry.begin({ pointerY: 0, time: 0 });
  carry.move({ pointerY: 3, time: 0 });
  stepFor(carry, { from: 0, seconds: 1, fps: 60 });

  const beforeRelease = carry.status().height;
  const released = carry.release({ time: 1 });
  assert.equal(released.phase, 'falling');
  assert.equal(released.height, beforeRelease);

  let previousHeight = released.height;
  for (let frame = 1; frame <= 30 && carry.status().phase === 'falling'; frame += 1) {
    const current = carry.update({ time: 1 + frame / 60 });
    assert.ok(current.height <= previousHeight + 1e-9);
    previousHeight = current.height;
  }
});

test('fall never crosses the ground and landing settles after cushioning', () => {
  const carry = createCarry();
  carry.begin({ pointerY: 0, time: 0 });
  carry.move({ pointerY: 2, time: 0 });
  stepFor(carry, { from: 0, seconds: 0.8, fps: 60 });
  carry.release({ time: 0.8 });

  let impactFrames = 0;
  let sawCompression = false;
  for (let frame = 1; frame <= 180; frame += 1) {
    const pose = carry.update({ time: 0.8 + frame / 60 });
    assert.ok(pose.height >= 0);
    assert.ok(Number.isFinite(pose.velocity));
    if (pose.impact > 0) {
      impactFrames += 1;
      assert.ok(pose.impact <= 1);
    }
    if (pose.phase === 'landing') {
      assert.ok(pose.landingProgress >= 0 && pose.landingProgress <= 1);
      assert.ok(pose.compression >= 0 && pose.compression <= 1);
      sawCompression ||= pose.compression > 0.2;
    }
  }

  assert.equal(impactFrames, 1);
  assert.equal(sawCompression, true);
  assert.deepEqual(carry.status(), {
    phase: 'idle',
    height: 0,
    velocity: 0,
    sway: 0
  });
});

test('motion remains consistent at 30 and 60 frames per second', () => {
  const simulate = fps => {
    const carry = createCarry();
    carry.begin({ pointerY: 0, time: 0 });
    carry.move({ pointerY: 4, time: 0 });
    stepFor(carry, { from: 0, seconds: 0.8, fps });
    carry.release({ time: 0.8 });
    const falling = stepFor(carry, { from: 0.8, seconds: 0.3, fps });
    stepFor(carry, { from: 1.1, seconds: 2, fps });
    return { falling, settled: carry.status() };
  };

  const at30 = simulate(30);
  const at60 = simulate(60);
  assert.ok(Math.abs(at30.falling.height - at60.falling.height) < 0.03);
  assert.ok(Math.abs(at30.falling.velocity - at60.falling.velocity) < 0.03);
  assert.equal(at30.settled.phase, 'idle');
  assert.equal(at60.settled.phase, 'idle');
});

test('quick pointer movement produces a bounded throw without a release pop', () => {
  const carry = createCarry();
  carry.begin({ pointerY: 0, time: 0 });
  carry.move({ pointerY: 1, time: 0.02 });
  carry.update({ time: 0.02 });

  const beforeRelease = carry.status().height;
  const released = carry.release({ time: 0.02 });
  assert.equal(released.height, beforeRelease);
  assert.ok(Math.abs(released.velocity) <= 8);

  const next = carry.update({ time: 0.12 });
  assert.ok(next.height - released.height < 0.8);
});

test('reset and reduced motion cancel carry immediately', () => {
  const carry = createCarry();
  carry.begin({ pointerY: 0, time: 0 });
  carry.move({ pointerY: 3, time: 0 });
  carry.update({ time: 0.2 });
  carry.reset();
  assert.equal(carry.status().phase, 'idle');
  assert.equal(carry.status().height, 0);

  carry.begin({ pointerY: 0, time: 1 });
  carry.move({ pointerY: 3, time: 1 });
  const reduced = carry.update({ time: 1.1, reducedMotion: true });
  assert.equal(reduced.phase, 'idle');
  assert.equal(reduced.height, 0);
});

test('invalid and non-monotonic input cannot corrupt carry state', () => {
  const carry = createCarry();
  carry.begin({ pointerY: 0, time: 1 });
  carry.move({ pointerY: 2, time: 1 });
  carry.update({ time: 1.1 });
  const valid = carry.status();

  carry.move({ pointerY: Number.NaN, time: 1.2 });
  carry.update({ time: Number.POSITIVE_INFINITY });
  carry.update({ time: 0.5 });
  carry.move({ pointerY: 100, time: 1.05 });
  carry.release({ time: Number.NaN });

  const after = carry.status();
  assert.equal(after.phase, valid.phase);
  assert.equal(after.height, valid.height);
  assert.ok(Object.values(after).every(value => typeof value !== 'number' || Number.isFinite(value)));

  carry.update({ time: 1.5 });
  assert.ok(carry.status().height < 2.1);
});
