import test from 'node:test';
import assert from 'node:assert/strict';
import { SIGNAL_CYCLE, createSeededScramble, signalAt } from '../Wallpaper/companion/crowd.js';

test('the lights cycle: cars, clear, walk, flashing, all red', () => {
  assert.equal(signalAt(1).phase, 'cars');
  assert.equal(signalAt(31).phase, 'clear');
  assert.equal(signalAt(34).walk, true);
  assert.equal(signalAt(54).flashing, true);
  assert.equal(signalAt(SIGNAL_CYCLE - 1).phase, 'allRed');
  assert.equal(signalAt(SIGNAL_CYCLE + 1).phase, 'cars');
});

test('people wait while the cars go and cross when the lights change', () => {
  const scramble = createSeededScramble(7);
  let frame = null;
  for (let t = 0; t <= 30; t += 0.1) frame = scramble.update(t);
  const waiting = frame.people.filter(person => person.state === 'wait').length;
  assert.ok(waiting > 15, `a crowd gathers at the kerbs (${waiting})`);
  assert.ok(frame.people.every(person => person.state !== 'cross' || person.z > 0), 'nobody crosses behind the camera');
  for (let t = 30.1; t <= 40; t += 0.1) frame = scramble.update(t);
  const crossing = frame.people.filter(person => person.state === 'cross').length;
  assert.ok(crossing > 10, `the scramble starts (${crossing})`);
  assert.equal(frame.cars.length, 0, 'no cars while people cross');
});

test('everyone is across before the cars go again', () => {
  const scramble = createSeededScramble(9);
  for (let t = 0; t < SIGNAL_CYCLE * 3; t += 0.1) {
    const frame = scramble.update(t);
    if (frame.signal.phase === 'cars' && frame.signal.remaining < 28) {
      const onRoad = frame.people.filter(person => person.state === 'cross').length;
      assert.equal(onRoad, 0, `nobody still crossing at ${t.toFixed(1)}s`);
    }
  }
});

test('cars only go through while the lights are with them', () => {
  const scramble = createSeededScramble(3);
  let cars = 0;
  for (let t = 0; t < SIGNAL_CYCLE * 2; t += 0.1) {
    const frame = scramble.update(t);
    if (frame.signal.walk) assert.equal(frame.cars.length, 0, `no cars at ${t.toFixed(1)}s`);
    cars = Math.max(cars, frame.cars.length);
  }
  assert.ok(cars > 2, 'there is traffic between the walking phases');
});

test('the crowd stays out of the spot right behind Miku and stays bounded', () => {
  const scramble = createSeededScramble(11);
  let most = 0;
  for (let t = 0; t < SIGNAL_CYCLE * 4; t += 0.1) {
    const frame = scramble.update(t);
    most = Math.max(most, frame.people.length);
    for (const person of frame.people) {
      if (person.state === 'wait' && person.origin === 'near') {
        assert.ok(person.x <= -0.9 || person.x >= 0.9, 'clear behind Miku');
      }
    }
  }
  assert.ok(most < 160, `bounded crowd (${most})`);
});

test('slow frames keep up with the lights: no cars left on the crossing when it turns green', () => {
  const scramble = createSeededScramble(5);
  // Two frames a second.
  for (let t = 0; t < SIGNAL_CYCLE * 2; t += 0.5) {
    const frame = scramble.update(t);
    if (frame.signal.walk) assert.equal(frame.cars.length, 0, `no cars at ${t}s`);
  }
  const later = createSeededScramble(6);
  later.update(0);
  later.update(20);
  const frame = later.update(34);
  assert.equal(frame.cars.length, 0, 'a long pause does not leave cars behind');
});

test('a full-cycle pause rebuilds without crossers in the car phase', () => {
  const scramble = createSeededScramble(1);
  scramble.update(0);
  const frame = scramble.update(SIGNAL_CYCLE);
  assert.equal(frame.signal.phase, 'cars');
  assert.equal(frame.people.filter(person => person.state === 'cross').length, 0);
  assert.ok(frame.cars.length > 0, 'traffic is rebuilt for the current car phase');
});

test('long pauses from different phases never mix crossing people with cars', () => {
  const starts = [0, 18, 34, 52];
  const gaps = [45, SIGNAL_CYCLE, 90, SIGNAL_CYCLE * 2, 300];
  for (const start of starts) {
    for (const gap of gaps) {
      const scramble = createSeededScramble(start + gap);
      for (let t = 0; t <= start; t += 0.1) scramble.update(t);
      const frame = scramble.update(start + gap);
      const crossing = frame.people.filter(person => person.state === 'cross').length;
      if (frame.signal.phase === 'cars') {
        assert.equal(crossing, 0, `no crossers after ${start}s + ${gap}s pause`);
      }
      if (frame.signal.walk) {
        assert.equal(frame.cars.length, 0, `no cars after ${start}s + ${gap}s pause`);
      }
    }
  }
});
