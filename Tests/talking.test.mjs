import test from 'node:test';
import assert from 'node:assert/strict';
import { MAX_VOICE_SECONDS, shouldFallBack, streamTalk, talkFrame, textTalk, voiceTalk } from '../Wallpaper/companion/talking.js';

test('a stream has no assumed utterance duration and stays active while audio arrives', () => {
  const talk = streamTalk('你好', 10);
  assert.equal(talk.streaming, true);
  assert.equal(talk.voiced, true);
  assert.ok(talkFrame(talk, 25));
  assert.equal(talkFrame(talk, 10 + MAX_VOICE_SECONDS + 1), null);
});

test('stream timing rejects missing text and an invalid clock', () => {
  assert.equal(streamTalk('', 0), null);
  assert.equal(streamTalk('hello', NaN), null);
  assert.deepEqual(talkFrame(streamTalk('，', 0), 2), { vowel: null, open: 0 });
});

test('a voiced line lasts exactly as long as its audio', () => {
  const talk = voiceTalk('辛苦晒～我陪你', 10, 3.2);
  assert.equal(talk.start, 10);
  assert.equal(talk.end, 13.2);
  assert.equal(talk.voiced, true);
  assert.ok(talkFrame(talk, 13.1));
  assert.equal(talkFrame(talk, 13.4), null);
});

test('long audio is not cut at the 8 s text limit', () => {
  const talk = voiceTalk('短い', 0, 12);
  assert.equal(talk.end, 12);
  assert.ok(textTalk('短い', 0).end < 1);
});

test('the characters are spread over the whole audio', () => {
  const talk = voiceTalk('あいうえお。', 0, 6);
  // The full stop is the last of six characters, so it falls in the last second.
  assert.equal(talkFrame(talk, 5.5).open, 0);
  assert.ok(talkFrame(talk, 0.2).vowel);
});

test('a bad or missing duration gives no voiced line', () => {
  assert.equal(voiceTalk('hi', 0, 0), null);
  assert.equal(voiceTalk('hi', 0, NaN), null);
  assert.equal(voiceTalk('', 0, 2), null);
  assert.equal(voiceTalk('hi', 0, 999).end, MAX_VOICE_SECONDS);
});

test('text-only bubbles keep the old timing', () => {
  const talk = textTalk('Hello there', 5);
  assert.equal(talk.voiced, false);
  assert.equal(talk.rate, 14);
  assert.equal(textTalk('a'.repeat(400), 0).end, 8);
});

test('the mouth closes on punctuation', () => {
  const talk = textTalk('、、、', 0);
  assert.deepEqual(talkFrame(talk, 0.1), { vowel: null, open: 0 });
});

test('a quick voice failure falls back to text timing, a late one does not', () => {
  const pending = { text: 'hi', at: 10 };
  assert.equal(shouldFallBack(pending, 11), true);
  assert.equal(shouldFallBack(pending, 20), false);
  assert.equal(shouldFallBack(null, 11), false);
});
