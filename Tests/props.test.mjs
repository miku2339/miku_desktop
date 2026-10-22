import test from 'node:test';
import assert from 'node:assert/strict';
import { chooseHandProp, hatFor, isTeaTime } from '../Wallpaper/companion/props.js';

test('umbrella only outdoors in rain or snow', () => {
  assert.equal(chooseHandProp({ weather: 'rain', scene: 'shinjuku' }), 'umbrella');
  assert.equal(chooseHandProp({ weather: 'snow', scene: 'ikebukuro' }), 'umbrella');
  assert.equal(chooseHandProp({ weather: 'rain', scene: 'hallway' }), null);
  assert.equal(chooseHandProp({ weather: 'clear', scene: 'shinjuku' }), null);
});

test('inside Shibuya station she carries her umbrella closed', () => {
  assert.equal(chooseHandProp({ weather: 'rain', scene: 'shibuya' }), 'closedUmbrella');
  assert.equal(chooseHandProp({ weather: 'clear', scene: 'shibuya' }), null);
  assert.equal(chooseHandProp({ weather: 'rain', scene: 'room' }), null);
});

test('nothing in her hands while she is busy or asleep', () => {
  assert.equal(chooseHandProp({ weather: 'rain', scene: 'shinjuku', idle: false }), null);
  assert.equal(chooseHandProp({ drinkUntil: 100, now: 10, awake: false }), null);
});

test('timed props while their time lasts', () => {
  assert.equal(chooseHandProp({ drinkUntil: 100, now: 10 }), 'drink');
  assert.equal(chooseHandProp({ drinkUntil: 100, now: 120 }), null);
  assert.equal(chooseHandProp({ leekUntil: 50, drinkUntil: 100, now: 10 }), 'leek');
  assert.equal(chooseHandProp({ cheerUntil: 50, leekUntil: 50, now: 10 }), 'glowsticks');
  assert.equal(chooseHandProp({ fanUntil: 50, now: 10 }), 'fan');
});

test('hats for special days', () => {
  assert.equal(hatFor(['christmas']), 'santa');
  assert.equal(hatFor(['christmasSeason']), 'santa');
  assert.equal(hatFor(['halloweenSeason']), 'witch');
  assert.equal(hatFor(['birthday']), 'party');
  assert.equal(hatFor(['anniversary', 'christmas']), 'party');
  assert.equal(hatFor(['snowMiku']), 'beanie');
  assert.equal(hatFor(['mikuDay']), null);
  assert.equal(hatFor([]), null);
});

test('tea time is mid-afternoon', () => {
  assert.equal(isTeaTime(15), true);
  assert.equal(isTeaTime(14.4), false);
  assert.equal(isTeaTime(16.6), false);
});
