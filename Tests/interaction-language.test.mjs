import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

import { GESTURE_PHRASES } from '../Wallpaper/companion/gestures.js';
import { createRelationship } from '../Wallpaper/companion/relationship.js';

const source = readFileSync(new URL('../Wallpaper/companion/companion.js', import.meta.url), 'utf8');

function section(start, end) {
  const from = source.indexOf(start);
  const to = source.indexOf(end, from);
  assert.ok(from >= 0 && to > from, `Missing companion section: ${start}`);
  return source.slice(from, to);
}

function createHarness() {
  const bubbles = [];
  const state = { language: 'zh-Hant', nextTouchSpeech: 0, thinking: false, weather: null };
  const relationship = createRelationship();
  const context = vm.createContext({
    GESTURE_PHRASES,
    currentElapsed: () => 100,
    currentHour: () => 12,
    hitTest() {},
    relationship,
    showBubble: (text, emotion) => bubbles.push({ text, emotion }),
    showsCharacter: true,
    speechBubble: { classList: { contains: () => false } },
    state,
    status: () => state,
    variety: {
      chance: () => false,
      line: (_key, phrases) => phrases[0],
      mood: () => 0,
      range: () => 0
    },
    window: {}
  });
  const pieces = [
    section('const HOVER_PHRASES =', 'const HOVER_NOTE_SYMBOLS'),
    section('const TOUCH_PHRASES =', 'const CONTEXT_PHRASES'),
    section('const CONTEXT_PHRASES =', 'const HOVER_GREETING_COOLDOWN'),
    section('const PROP_PHRASES =', 'function sayProp('),
    section('function sayProp(', 'const GREETING_ORDER'),
    section('function gestureSay(', 'const gestures ='),
    section('function sayNow(', 'function reactToShaking('),
    section('function browserReactionText(', 'function handlePointerDown('),
    section('function pickPhrase(', '/** Called for every pointer position'),
    section('window.mikuCompanion = Object.freeze({', "\n\ndocument.body.classList.toggle('interaction-enabled'")
  ];
  vm.runInContext(`${pieces.join('\n')}\n globalThis.phrases = { HOVER_PHRASES, TOUCH_PHRASES, CONTEXT_PHRASES, PROP_PHRASES, GESTURE_PHRASES };`, context);
  return { context, state, bubbles, relationship, api: context.window.mikuCompanion };
}

function assertKorean(text) {
  assert.match(text, /[가-힣]/u);
  assert.doesNotMatch(text, /[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}]/u);
}

test('Korean is accepted by the desktop API and hover and browser reactions use Korean', () => {
  const harness = createHarness();
  assert.equal(harness.api.setLanguage('ko'), true);
  assert.equal(harness.state.language, 'ko');
  for (const zone of ['head', 'hand', 'body']) {
    assertKorean(harness.context.pickPhrase(zone));
    for (const text of harness.context.browserReactionText(zone)) assertKorean(text);
  }
  harness.api.setLanguage('unsupported');
  assert.equal(harness.state.language, 'zh-Hant');
});

test('Korean touch replies preserve distant, close and offended relationship reactions', () => {
  const harness = createHarness();
  harness.api.setLanguage('ko');
  harness.relationship.set({ friendship: 10 });
  harness.context.showTouchPhrase('handHold');
  const distant = harness.bubbles.at(-1).text;
  assertKorean(distant);
  assert.match(distant, /갑자기/);
  harness.relationship.set({ friendship: 80 });
  harness.context.showTouchPhrase('handHold');
  assertKorean(harness.bubbles.at(-1).text);
  assert.notEqual(harness.bubbles.at(-1).text, distant);
  harness.relationship.noteBoundary();
  harness.context.showTouchPhrase('handHold');
  assert.match(harness.bubbles.at(-1).text, /사과/);
  assert.equal(harness.bubbles.at(-1).emotion, 'pout');
});

test('Korean sleep, waking, carrying and gesture replies reach the speech bubble', () => {
  const harness = createHarness();
  harness.api.setLanguage('ko');
  for (const key of ['carry', 'shaking', 'ouch', 'boundary', 'boundarySkirt', 'goodnight', 'sleepMumble', 'wokenUp', 'morning']) {
    harness.context.sayNow(key);
    assertKorean(harness.bubbles.at(-1).text);
  }
  for (const key of ['dance', 'yawn', 'wake', 'thunder', 'rainFeel']) {
    harness.context.gestureSay({}, 1, key);
    assertKorean(harness.bubbles.at(-1).text);
  }
});

test('Korean weather, props and special-day greetings keep their language', () => {
  const harness = createHarness();
  harness.api.setLanguage('ko');
  for (const weather of ['rain', 'storm', 'snow', 'fog']) {
    harness.state.weather = { kind: weather };
    assertKorean(harness.context.contextLine());
  }
  for (const key of ['leek', 'drink', 'fan', 'listen', 'rain', 'birthday', 'anniversary', 'christmas', 'snowMiku', 'magicalMirai']) {
    assert.equal(harness.context.sayProp(key), true);
    assertKorean(harness.bubbles.at(-1).text);
  }
});

test('all desktop interaction phrase categories have complete Korean alternatives', () => {
  const { context } = createHarness();
  for (const [name, phrases] of Object.entries(context.phrases)) {
    assert.deepEqual(Object.keys(phrases.ko).sort(), Object.keys(phrases.en).sort(), name);
    for (const [key, alternatives] of Object.entries(phrases.ko)) {
      assert.ok(alternatives.length > 0, `${name}.${key}`);
      assert.ok(alternatives.some(text => /[가-힣]/u.test(text)), `${name}.${key}`);
      assert.ok(alternatives.every(text => typeof text === 'string' && text.trim().length > 0), `${name}.${key}`);
    }
  }
});
