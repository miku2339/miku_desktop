import test from 'node:test';
import assert from 'node:assert/strict';
import { createSleepCycle, isAsleep, normalizeOverride, scheduledAsleep } from '../Wallpaper/companion/sleep.js';

test('she sleeps from 1:00 to 7:00 by default', () => {
  assert.equal(scheduledAsleep(0.5), false);
  assert.equal(scheduledAsleep(1), true);
  assert.equal(scheduledAsleep(6.99), true);
  assert.equal(scheduledAsleep(7), false);
  assert.equal(scheduledAsleep(23, 22, 7), true);
  assert.equal(scheduledAsleep(NaN), false);
});

test('an override from the app wins until it runs out', () => {
  const night = { asleep: true, until: 1000 };
  assert.equal(isAsleep({ hour: 22, nowMs: 500, override: night }), true);
  assert.equal(isAsleep({ hour: 22, nowMs: 1500, override: night }), false);
  assert.equal(isAsleep({ hour: 3, nowMs: 500, override: { asleep: false, until: 1000 } }), false);
  assert.equal(normalizeOverride({ asleep: 'yes', until: 5 }), null);
  assert.equal(normalizeOverride(null), null);
});

test('going to bed: wind down, fade out, swap to lying while invisible, fade in', () => {
  const cycle = createSleepCycle({ windDown: 3, fade: 0.5 });
  let s = cycle.step({ time: 0, wantAsleep: true });
  assert.equal(s.phase, 'windingDown');
  s = cycle.step({ time: 3.1, wantAsleep: true });
  assert.equal(s.phase, 'dimming');
  s = cycle.step({ time: 3.3, wantAsleep: true });
  assert.equal(s.lying, false);
  assert.ok(s.visibility < 1 && s.visibility > 0);
  s = cycle.step({ time: 3.65, wantAsleep: true });
  assert.equal(s.lying, true, 'swapped after the black point');
  s = cycle.step({ time: 5, wantAsleep: true });
  assert.equal(s.phase, 'lying');
  assert.equal(s.visibility, 1);
  // Getting up.
  s = cycle.step({ time: 10, wantAsleep: false });
  assert.equal(s.phase, 'brightening');
  assert.equal(s.lying, true);
  s = cycle.step({ time: 10.7, wantAsleep: false });
  assert.equal(s.lying, false);
  s = cycle.step({ time: 12, wantAsleep: false });
  assert.equal(s.phase, 'awake');
});

test('she waits while you hold her, and only dozes without a bed', () => {
  const cycle = createSleepCycle({ windDown: 1, fade: 0.5 });
  assert.equal(cycle.step({ time: 0, wantAsleep: true, busy: true }).phase, 'awake');
  cycle.step({ time: 1, wantAsleep: true });
  assert.equal(cycle.step({ time: 2.5, wantAsleep: true, canLie: false }).phase, 'dozing');
  assert.equal(cycle.step({ time: 9, wantAsleep: true, canLie: false }).lying, false);
  assert.equal(cycle.step({ time: 10, wantAsleep: false }).phase, 'awake');
});
