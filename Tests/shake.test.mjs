import test from 'node:test';
import assert from 'node:assert/strict';
import { createShake, shakeAftermath } from '../Wallpaper/companion/shake.js';

function shakeFor(shake, { seconds, hz, amplitude, axis = 'x', start = 0, step = 1 / 60 }) {
  let state;
  for (let time = start; time <= start + seconds; time += step) {
    const offset = Math.sin(time * hz * Math.PI * 2) * amplitude;
    state = shake.sample({ x: axis === 'x' ? 0.4 + offset : 0.4, y: axis === 'y' ? 0.5 + offset : 0.5, time });
  }
  return state;
}

test('a steady drag across the screen is not a shake', () => {
  const shake = createShake();
  shake.begin(0);
  let state;
  for (let time = 0; time <= 2; time += 1 / 60) state = shake.sample({ x: 0.2 + time * 0.25, y: 0.5, time });
  assert.equal(state.dizziness, 0);
  assert.equal(state.shaking, false);
});

test('a slow lazy sway barely registers', () => {
  const shake = createShake();
  shake.begin(0);
  const state = shakeFor(shake, { seconds: 3, hz: 0.5, amplitude: 0.08 });
  assert.ok(state.peak < 0.1, `peak ${state.peak}`);
});

test('vigorous side-to-side shaking makes her dizzy', () => {
  const shake = createShake();
  shake.begin(0);
  const state = shakeFor(shake, { seconds: 2, hz: 3, amplitude: 0.12 });
  assert.equal(state.shaking, true);
  assert.ok(state.dizziness > 0.6, `dizziness ${state.dizziness}`);
  assert.ok(state.peak >= state.dizziness);
});

test('up-and-down shaking counts too', () => {
  const shake = createShake();
  shake.begin(0);
  const state = shakeFor(shake, { seconds: 1.5, hz: 3, amplitude: 0.1, axis: 'y' });
  assert.ok(state.dizziness > 0.4, `dizziness ${state.dizziness}`);
});

test('dizziness wears off after release but the peak is kept until the next pick-up', () => {
  const shake = createShake();
  shake.begin(0);
  const shaken = shakeFor(shake, { seconds: 2, hz: 3, amplitude: 0.12 });
  shake.release(2);
  const later = shake.update(8);
  assert.ok(later.dizziness < shaken.dizziness * 0.1);
  assert.equal(later.peak, shaken.peak);
  assert.equal(later.shaking, false);
  const again = shake.begin(9);
  assert.ok(again.peak < 0.05);
});

test('aftermath escalates from dizzy to pouting to sulking', () => {
  const random = () => 0.9;
  assert.equal(shakeAftermath({ peak: 0.1 }), null);
  assert.equal(shakeAftermath({ peak: 0.8, recentShakes: 0, random }).style, 'recover');
  assert.equal(shakeAftermath({ peak: 0.8, recentShakes: 1, random }).style, 'pout');
  assert.equal(shakeAftermath({ peak: 0.8, recentShakes: 4, random }).style, 'sulk');
  assert.equal(shakeAftermath({ peak: 0.4, recentShakes: 0, random: () => 0 }).style, 'giggle');
});

test('a hard drop without shaking hurts instead', () => {
  const result = shakeAftermath({ peak: 0.05, impact: 0.8, random: () => 0.2 });
  assert.equal(result.type, 'ouch');
  assert.ok(result.duration > 3);
  assert.equal(shakeAftermath({ peak: 0.05, impact: 0.3 }), null);
});

test('ignores bad samples and samples before begin', () => {
  const shake = createShake();
  assert.equal(shake.sample({ x: 0.1, y: 0.1, time: 0 }).dizziness, 0);
  shake.begin(0);
  shake.sample({ x: 0.1, y: 0.1, time: 0.1 });
  assert.equal(shake.sample({ x: NaN, y: 0.1, time: 0.2 }).dizziness, 0);
  assert.equal(shake.sample({ x: 0.9, y: 0.1, time: 0.05 }).dizziness, 0);
});
