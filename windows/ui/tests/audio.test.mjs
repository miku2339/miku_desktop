import test from 'node:test';
import assert from 'node:assert/strict';
import { VoiceController } from '../audio.mjs';

function deferred() { let resolve; const promise = new Promise(done => { resolve = done; }); return { promise, resolve }; }
function setup(overrides = {}) {
  const calls = [], states = [], errors = [], texts = [];
  const controller = new VoiceController({
    invoke: async (command, args) => { calls.push({ command, args }); return {}; },
    action: async (action, payload) => { calls.push({ action, payload }); return {}; },
    settings: () => ({ speechProvider: 'system', replyLanguage: 'ja', speechRecognitionLanguage: 'yue' }),
    onState: state => states.push(state), onText: text => texts.push(text), onReply: () => {}, onError: error => errors.push(error),
    ...overrides,
  });
  return { controller, calls, states, errors, texts };
}

test('microphone opens only on explicit listen and uses selected recognition language', async () => {
  const request = deferred();
  const { controller, calls, texts } = setup({ invoke: async (command, args) => { calls.push({ command, args }); return command === 'desktop_listen' ? request.promise : {}; } });
  assert.equal(calls.length, 0);
  const listening = controller.listenOnce();
  assert.equal(calls[0].command, 'desktop_listen');
  assert.equal(calls[0].args.language, 'yue');
  await controller.stop();
  request.resolve({ text: '這是已取消的輸入' });
  await listening;
  assert.deepEqual(texts, []);
  assert.equal(controller.listening, false);
  assert.ok(calls.some(call => call.args?.action === 'listen_stop'));
});

test('native mouth sync waits for speaking status and always ends', async () => {
  const { controller, calls } = setup({ invoke: async (command, args) => {
    calls.push({ command, args });
    if (command === 'desktop_speak') return { jobId: 'speech-1', state: 'starting' };
    if (args?.action === 'speak_status') return { state: 'speaking', completed: true };
    return {};
  } });
  await controller.speak('こんにちは', 'ja');
  const start = calls.findIndex(call => call.action === 'voice_started');
  const status = calls.findIndex(call => call.args?.action === 'speak_status');
  assert.ok(start > status);
  assert.deepEqual(calls[start].payload, { text: 'こんにちは', duration: 0, jobId: 'speech-1' });
  assert.equal(calls.at(-1).action, 'voice_ended');
  assert.deepEqual(calls.at(-1).payload, { jobId: 'speech-1' });
  assert.equal(controller.speaking, false);
});

test('native speech failure clears mouth sync and exposes the error', async () => {
  const { controller, calls } = setup({ invoke: async (command, args) => {
    if (command === 'desktop_speak') return { jobId: 'speech-2' };
    if (args?.action === 'speak_status') return { state: 'failed', error: 'No voice installed' };
    return {};
  } });
  await assert.rejects(controller.speak('Test'), /No voice installed/);
  assert.equal(calls.at(-1).action, 'voice_ended');
  assert.equal(calls.filter(call => call.action === 'voice_started').length, 0);
});

test('local audio starts mouth on playback instead of during generation', async t => {
  const previous = globalThis.Audio;
  t.after(() => { if (previous === undefined) delete globalThis.Audio; else globalThis.Audio = previous; });
  class Playback extends EventTarget {
    constructor(source) { super(); this.src = source; this.duration = 2.5; }
    play() { queueMicrotask(() => { this.dispatchEvent(new Event('playing')); queueMicrotask(() => this.dispatchEvent(new Event('ended'))); }); return Promise.resolve(); }
    pause() { this.dispatchEvent(new Event('pause')); }
  }
  globalThis.Audio = Playback;
  const request = deferred();
  const { controller, calls } = setup({ settings: () => ({ speechProvider: 'local' }), action: async (action, payload) => { calls.push({ action, payload }); return action === 'voice_request' ? request.promise : {}; } });
  const speaking = controller.speak('Hello', 'en');
  assert.equal(calls.some(call => call.action === 'voice_started'), false);
  request.resolve({ jobId: 101, audio: 'YQ==', mimeType: 'audio/wav' });
  await speaking;
  assert.deepEqual(calls.find(call => call.action === 'voice_started').payload, { text: 'Hello', duration: 2.5, jobId: 101 });
  assert.equal(calls.at(-1).action, 'voice_ended');
  assert.deepEqual(calls.at(-1).payload, { jobId: 101 });
});

test('cancelled local generation never starts or stops a later speech job', async () => {
  const request = deferred();
  const { controller, calls } = setup({ settings: () => ({ speechProvider: 'local' }), action: async (action, payload) => { calls.push({ action, payload }); return action === 'voice_request' ? request.promise : {}; } });
  const speaking = controller.speak('Old reply');
  await controller.stop();
  const ends = calls.filter(call => call.action === 'voice_ended').length;
  request.resolve({ audio: 'YQ==', mimeType: 'audio/wav' });
  await speaking;
  assert.equal(calls.some(call => call.action === 'voice_started'), false);
  assert.equal(calls.filter(call => call.action === 'voice_ended').length, ends);
});

test('ending a call cancels microphone and pending model work', async () => {
  const request = deferred();
  const { controller, calls } = setup({ invoke: async (command, args) => { calls.push({ command, args }); return command === 'desktop_listen' ? request.promise : {}; } });
  const call = controller.startCall();
  await Promise.resolve();
  await controller.stop();
  request.resolve({ text: 'Cancelled' });
  await call;
  assert.ok(calls.some(value => value.action === 'voice_call_started'));
  assert.ok(calls.some(value => value.action === 'voice_call_ended'));
  assert.ok(calls.some(value => value.action === 'chat_cancel'));
  assert.equal(calls.some(value => value.command === 'desktop_send_message'), false);
  assert.equal(controller.calling, false);
});


test('manual read stops an active call microphone before playing external audio', async () => {
  const { controller, calls } = setup({ invoke: async (command, args) => {
    calls.push({ command, args });
    if (command === 'desktop_speak') return { jobId: 3 };
    if (args?.action === 'speak_status') return { state: 'completed' };
    return {};
  } });
  controller.calling = true; controller.listening = true;
  await controller.speak('Manual playback');
  const stopped = calls.findIndex(call => call.args?.action === 'listen_stop');
  const speaking = calls.findIndex(call => call.command === 'desktop_speak');
  assert.ok(stopped >= 0 && speaking > stopped);
  assert.ok(calls.some(call => call.action === 'voice_call_ended'));
  assert.equal(controller.calling, false);
  assert.equal(controller.listening, false);
});

test('streamed phrases play in order and duplicate or stale events cannot replay', async () => {
  const { controller } = setup();
  controller.calling = true; controller.generation = 4; controller.resetStream(4);
  const first = deferred(); const played = [];
  controller.speak = async text => { played.push(text); if (text === 'First.') await first.promise; };
  controller.enqueueSegment({ voiceGeneration: 4, voiceTurnId: 'turn-4', sequence: 0, text: 'First.', language: 'en' });
  controller.enqueueSegment({ voiceGeneration: 4, voiceTurnId: 'turn-4', sequence: 0, text: 'Duplicate.', language: 'en' });
  controller.enqueueSegment({ voiceGeneration: 3, voiceTurnId: 'turn-3', sequence: 1, text: 'Stale.', language: 'en' });
  controller.enqueueSegment({ voiceGeneration: 4, voiceTurnId: 'different-turn', sequence: 1, text: 'Wrong turn.', language: 'en' });
  controller.enqueueSegment({ voiceGeneration: 4, voiceTurnId: 'turn-4', sequence: 1, text: 'Second.', language: 'en' });
  await Promise.resolve();
  assert.deepEqual(played, ['First.']);
  first.resolve(); await controller.drainStream(4);
  assert.deepEqual(played, ['First.', 'Second.']);
  assert.equal(controller.streamCompletedText, 'First.Second.');
});

test('stopping a streamed reply clears pending phrases and completed progress', async () => {
  const { controller } = setup();
  controller.calling = true; controller.generation = 7; controller.resetStream(7);
  const first = deferred(); const played = [];
  controller.speak = async text => { played.push(text); await first.promise; };
  controller.enqueueSegment({ voiceGeneration: 7, voiceTurnId: 'turn-7', sequence: 0, text: 'First.' });
  controller.enqueueSegment({ voiceGeneration: 7, voiceTurnId: 'turn-7', sequence: 1, text: 'Must not play.' });
  const queued = controller.streamQueue;
  await Promise.resolve(); await controller.stop(); first.resolve(); await queued;
  assert.deepEqual(played, ['First.']);
  assert.equal(controller.streamCompletedText, '');
  controller.enqueueSegment({ voiceGeneration: 7, voiceTurnId: 'turn-7', sequence: 2, text: 'Late.' });
  assert.equal(controller.streamSequence, 0);
});

test('voice call requests streaming, drains audio before listening and skips full reply replay', async () => {
  const playback = deferred(), nextInput = deferred();
  const spoken = []; let listens = 0;
  const { controller } = setup({ invoke: async (command, args) => {
    if (command === 'desktop_listen') { listens += 1; return listens === 1 ? { text: 'Hello' } : nextInput.promise; }
    if (command === 'desktop_send_message') {
      assert.equal(args.voiceStream, true);
      assert.equal(args.voiceGeneration, controller.generation);
      controller.enqueueSegment({ voiceGeneration: args.voiceGeneration, voiceTurnId: 'stream-turn', sequence: 0, text: 'A streamed answer.', language: 'en' });
      return { voiceStreamed: true, voiceTurnId: 'stream-turn', text: 'A streamed answer.', language: 'en' };
    }
    return {};
  } });
  controller.speak = async text => { spoken.push(text); await playback.promise; };
  const calling = controller.startCall();
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(spoken, ['A streamed answer.']);
  assert.equal(listens, 1);
  playback.resolve(); await new Promise(resolve => setImmediate(resolve));
  assert.equal(listens, 2);
  assert.deepEqual(spoken, ['A streamed answer.']);
  await controller.stop(); nextInput.resolve({ text: '' }); await calling;
});

test('out-of-order streamed phrases stop the call instead of playing an invalid continuation', async () => {
  const { controller, errors } = setup();
  controller.calling = true; controller.generation = 2; controller.resetStream(2);
  controller.enqueueSegment({ voiceGeneration: 2, voiceTurnId: 'turn-2', sequence: 1, text: 'Missing first phrase.' });
  await Promise.resolve();
  assert.equal(controller.calling, false);
  assert.match(errors[0].message, /voice-stream-invalid/);
});


test('manual interruption reports completed speech and waits for backend settlement before reopening the microphone', async () => {
  const settled = deferred(), input = deferred();
  const { controller, calls } = setup({
    invoke: async (command, args) => { calls.push({ command, args }); return command === 'desktop_listen' ? input.promise : {}; },
    action: async (action, payload) => { calls.push({ action, payload }); return action === 'voice_call_interrupt' ? settled.promise : {}; },
  });
  controller.calling = true; controller.generation = 5; controller.resetStream(5);
  controller.currentVoiceTurnId = 'known-turn';
  controller.currentUserText = 'Tell me a story'; controller.currentReplyId = 'reply-1';
  controller.streamCompletedText = 'First completed sentence.'; controller.turnStarted = true;
  const interruption = controller.interruptAndListen();
  await Promise.resolve();
  assert.equal(calls.some(call => call.command === 'desktop_listen'), false);
  assert.deepEqual(calls.find(call => call.action === 'voice_call_interrupt').payload, { voiceGeneration: 5, voiceTurnId: 'known-turn', completedText: 'First completed sentence.', started: true, replyId: 'reply-1', userText: 'Tell me a story' });
  settled.resolve({}); await new Promise(resolve => setImmediate(resolve));
  assert.ok(calls.some(call => call.command === 'desktop_stop_speech'));
  assert.ok(calls.some(call => call.command === 'desktop_listen'));
  await controller.stop(); input.resolve({ text: '' }); await interruption;
});


test('voice game replies play and continue without a streaming turn token', async () => {
  const input = deferred(), replies = [], spoken = []; let listens = 0;
  const { controller, errors } = setup({
    invoke: async command => {
      if (command === 'desktop_listen') return ++listens === 1 ? { text: 'Let us play rock paper scissors' } : input.promise;
      if (command === 'desktop_send_message') return { game: 'rps', text: 'Choose a hand.', language: 'en', choices: [{ id: 'rock', title: 'Rock' }], state: { type: 'rps', isOver: false } };
      return {};
    },
    onReply: reply => replies.push(reply),
  });
  controller.speak = async text => { spoken.push(text); };
  const calling = controller.startCall();
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(spoken, ['Choose a hand.']);
  assert.equal(replies[0].choices[0].id, 'rock');
  assert.equal(controller.currentVoiceTurnId, null);
  assert.equal(listens, 2);
  assert.deepEqual(errors, []);
  await controller.stop(); input.resolve({ text: '' }); await calling;
});


test('rejected call ownership does not stop audio or microphone owned by another window', async () => {
  const { controller, calls, errors } = setup({ action: async (action, payload) => {
    calls.push({ action, payload });
    if (action === 'voice_call_started') throw new Error('Another window is calling');
    return {};
  } });
  await controller.startCall();
  assert.equal(controller.calling, false);
  assert.match(errors[0].message, /Another window/);
  assert.equal(calls.some(call => call.command === 'desktop_stop_speech'), false);
  assert.equal(calls.some(call => call.args?.action === 'listen_stop'), false);
  assert.equal(calls.some(call => call.action === 'voice_call_ended'), false);
});
