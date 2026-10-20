import assert from 'node:assert/strict';
import test from 'node:test';

import { createRoutine, createVariety, mulberry32 } from '../Wallpaper/companion/variety.js';

test('pick never repeats the previous choice for the same key', () => {
  const variety = createVariety(mulberry32(7));
  let previous = null;
  for (let index = 0; index < 200; index += 1) {
    const choice = variety.pick('poke', ['wink', 'surprised', 'pout', 'flustered']);
    assert.notEqual(choice, previous);
    previous = choice;
  }
});

test('pick respects weights', () => {
  const variety = createVariety(mulberry32(3));
  const counts = { a: 0, b: 0, c: 0 };
  for (let index = 0; index < 3000; index += 1) counts[variety.pick(`k${index}`, ['a', 'b', 'c'], { a: 8 })] += 1;
  assert.ok(counts.a > counts.b * 3 && counts.a > counts.c * 3);
});

test('line uses every phrase before repeating and never repeats back to back', () => {
  const variety = createVariety(mulberry32(11));
  const lines = ['one', 'two', 'three', 'four'];
  let previous = null;
  for (let round = 0; round < 25; round += 1) {
    const seen = new Set();
    for (let index = 0; index < lines.length; index += 1) {
      const line = variety.line('k', lines);
      assert.notEqual(line, previous);
      seen.add(line);
      previous = line;
    }
    assert.equal(seen.size, lines.length);
  }
});

test('mood rises with repeated touches and fades after 30 seconds', () => {
  const variety = createVariety(mulberry32(5));
  assert.equal(variety.mood(0), 0);
  for (let index = 0; index < 8; index += 1) variety.noteTouch(index);
  assert.ok(variety.mood(8) > 0.9);
  assert.equal(variety.mood(60), 0);
});

test('routine is stable for a seed, differs across seeds and never loops back to a fixed cycle', () => {
  const a = createRoutine({ seed: 1 });
  const b = createRoutine({ seed: 1 });
  const c = createRoutine({ seed: 2 });
  const names = routine => Array.from({ length: 300 }, (_, index) => routine.behaviorAt(index * 2).name).join(',');
  assert.equal(names(a), names(b));
  assert.notEqual(names(a), names(c));
  const timeline = Array.from({ length: 600 }, (_, index) => a.behaviorAt(index).name);
  assert.notEqual(timeline.slice(0, 150).join(), timeline.slice(150, 300).join());
});

test('routine walks connect: each walk starts where she last stood, within the screen range', () => {
  const routine = createRoutine({ seed: 42, minAnchor: 0.2, maxAnchor: 0.64, startAnchor: 0.22 });
  let anchor = 0.22;
  for (let time = 0; time < 1500; time += 0.5) {
    const behavior = routine.behaviorAt(time);
    if (behavior.name === 'walk') {
      assert.ok(Math.abs(behavior.fromAnchor - anchor) < 1e-9, `walk at ${time} starts at ${behavior.fromAnchor}, expected ${anchor}`);
      assert.ok(behavior.toAnchor >= 0.2 && behavior.toAnchor <= 0.64);
      if (behavior.progress > 0.99) anchor = behavior.toAnchor;
    } else {
      const resting = routine.restingAnchorAt(time);
      if (Math.abs(resting - anchor) > 1e-9) anchor = resting; // finished a walk between samples
    }
  }
});

test('routine mixes all idle actions', () => {
  const routine = createRoutine({ seed: 9 });
  const seen = new Set();
  for (let time = 0; time < 3000; time += 1) seen.add(routine.behaviorAt(time).name);
  for (const name of ['idle', 'walk', 'lookAround', 'hum', 'wave', 'stretch', 'rest-standing']) assert.ok(seen.has(name), name);
});
