import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import {
  blendPoses, createSleepPoser, SHIFT_SECONDS, SLEEP_POSES, stirEnvelope
} from '../Wallpaper/companion/sleep-pose.js';
import { createSleepCycle, isAsleep } from '../Wallpaper/companion/sleep.js';

/** A repeatable stand-in for Math.random. */
function seeded(seed = 7) {
  let value = seed;
  return () => {
    value = (value * 16807) % 2147483647;
    return (value - 1) / 2147483646;
  };
}

function run(poser, seconds, fps = 30, start = 0) {
  const frames = [];
  for (let frame = 0; frame <= seconds * fps; frame += 1) {
    const t = start + frame / fps;
    frames.push({ t, ...poser.step(t) });
  }
  return frames;
}

test('a blend starts at one pose and ends at the other', () => {
  const [curled, nearFace] = SLEEP_POSES;
  assert.deepEqual(blendPoses(curled, nearFace, 0), {
    spine: curled.spine, neck: curled.neck, head: curled.head, arms: curled.arms
  });
  assert.deepEqual(blendPoses(curled, nearFace, 1), {
    spine: nearFace.spine, neck: nearFace.neck, head: nearFace.head, arms: nearFace.arms
  });
  const half = blendPoses(curled, nearFace, 0.5);
  assert.equal(half.spine, (curled.spine + nearFace.spine) / 2);
});

test('every pose bends the same bones on both sides', () => {
  for (const pose of SLEEP_POSES) {
    assert.deepEqual(Object.keys(pose.arms).sort(), ['右', '左']);
    for (const side of ['左', '右']) {
      assert.deepEqual(Object.keys(pose.arms[side]).sort(), ['ひじ', '手首', '腕'].sort());
    }
  }
});

test('a touch stirs her gently, then she settles again', () => {
  assert.equal(stirEnvelope(-1), 0);
  assert.equal(stirEnvelope(Infinity), 0);
  assert.equal(stirEnvelope(0), 0);
  assert.ok(stirEnvelope(0.05) < 0.1, 'no snap at the moment of the touch');
  assert.equal(stirEnvelope(0.3), 1);
  assert.ok(stirEnvelope(1) > 0 && stirEnvelope(1) < 1);
  assert.equal(stirEnvelope(2), 0);
});

test('the night starts curled up, as calibrated under the blanket', () => {
  const poser = createSleepPoser(seeded());
  poser.reset(100);
  const first = poser.step(100);
  assert.equal(first.poseName, 'curled');
  assert.deepEqual(first.pose.arms, SLEEP_POSES[0].arms);
});

test('going back to bed resets her pose before she fades in', () => {
  const source = readFileSync(new URL('../Wallpaper/companion/companion.js', import.meta.url), 'utf8');
  const start = source.indexOf('function updateSleep(');
  const end = source.indexOf('\n\n/** Fades the character', start);
  assert.ok(start >= 0 && end > start);
  const sleepPoser = createSleepPoser(() => 0.5);
  const context = vm.createContext({
    canUseRoomBed: () => true,
    carry: { status: () => ({ phase: 'idle' }) },
    isAsleep,
    reducedMotion: { matches: true },
    roomBlanketsReady: true,
    roomLayout: {},
    sayNow() {},
    showsCharacter: true,
    sleepCycle: createSleepCycle(),
    sleepOverride: { asleep: true, until: Number.MAX_SAFE_INTEGER },
    sleepPoser,
    sleepState: { phase: 'awake', lying: false },
    sleepTouch: { pendingBoundary: null, stirs: [], wokenEarly: false },
    state: { loadedScenes: ['room'], pointer: null, reaction: null }
  });
  vm.runInContext(source.slice(start, end), context, { filename: 'companion.js#sleep-cycle' });
  function frame(time) {
    context.updateSleep(time, 2);
    return context.sleepState.lying ? sleepPoser.step(time) : null;
  }

  for (const time of [0, 3.6, 4.31, 5.01, 460, 463]) frame(time);
  assert.equal(sleepPoser.step(463).poseName, 'relaxed');
  context.sleepOverride.asleep = false;
  for (const time of [500, 500.71, 501.41]) frame(time);
  assert.equal(context.sleepState.phase, 'awake');

  context.sleepOverride.asleep = true;
  for (const time of [1000, 1003.6]) frame(time);
  const fadingIn = frame(1004.31);
  assert.equal(context.sleepState.phase, 'dimming');
  assert.ok(context.sleepState.visibility < 0.02);
  assert.deepEqual(fadingIn.pose.arms, SLEEP_POSES[0].arms);
  const visible = frame(1004.95);
  const settled = frame(1005.01);
  assert.equal(context.sleepState.phase, 'lying');
  assert.deepEqual(visible.pose.arms, settled.pose.arms);
});

test('she breathes slowly and visibly, in and out', () => {
  const frames = run(createSleepPoser(seeded()), 60);
  const breaths = frames.map(frame => frame.breath);
  assert.ok(Math.max(...breaths) > 0.95 && Math.min(...breaths) < -0.95);
  const rises = frames.filter((frame, index) => index > 0 && frames[index - 1].breath < 0 && frame.breath >= 0);
  assert.ok(rises.length >= 12 && rises.length <= 16, `${rises.length} breaths a minute`);
});

test('now and then she shifts into another position, slowly', () => {
  const frames = run(createSleepPoser(seeded()), 40 * 60, 4);
  const names = frames.map(frame => frame.poseName);
  const changes = names.filter((name, index) => index > 0 && name !== names[index - 1]).length;
  assert.ok(changes >= 3 && changes <= 10, `${changes} shifts in 40 minutes`);
  assert.equal(frames.slice(0, 4 * 230).some(frame => frame.shifting), false, 'settled for the first few minutes');
  // A shift takes a couple of seconds, never a single frame.
  const start = frames.findIndex(frame => frame.shifting);
  const shifting = frames.slice(start).findIndex(frame => !frame.shifting);
  assert.ok(shifting / 4 >= SHIFT_SECONDS - 0.5, `shift took ${shifting / 4} s`);
});

test('she nuzzles into the pillow every minute or few', () => {
  const frames = run(createSleepPoser(seeded()), 10 * 60, 10);
  const nuzzles = frames.filter((frame, index) => index > 0 && frame.nuzzle > 0 && frames[index - 1].nuzzle === 0).length;
  assert.ok(nuzzles >= 3 && nuzzles <= 10, `${nuzzles} nuzzles in 10 minutes`);
  assert.ok(frames.every(frame => frame.nuzzle >= 0 && frame.nuzzle <= 1));
});

test('the sleepy z’s float up at an uneven pace', () => {
  const frames = run(createSleepPoser(seeded()), 120);
  const times = frames.filter(frame => frame.z).map(frame => frame.t);
  const gaps = times.slice(1).map((t, index) => t - times[index]);
  assert.ok(gaps.length > 30);
  assert.ok(gaps.every(gap => gap >= 1.39 && gap <= 3.65));
  assert.ok(Math.max(...gaps) - Math.min(...gaps) > 1, 'not a metronome');
});
