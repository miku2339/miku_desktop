import assert from 'node:assert/strict';
import test from 'node:test';

import { createDailyActivities } from '../Wallpaper/companion/daily-activities.js';

const activeOptions = {
  initialDelay: [0, 0],
  betweenDelay: [0, 0]
};

const context = {
  hour: 15,
  scene: 'shibuya',
  weather: 'clear',
  musicPlaying: true
};

function activitySequence(seed) {
  const activities = createDailyActivities({ seed, ...activeOptions });
  const sequence = [];
  let previous = null;
  for (let time = 0; time <= 900; time += 1) {
    const sample = activities.update({ time, currentAnchor: 0.3, context, propReady: true });
    if (sample.activity && sample.activity !== previous) sequence.push(sample.activity);
    previous = sample.activity;
  }
  return sequence;
}

test('seeded activity choices are reproducible without immediate repeats', () => {
  const first = activitySequence(31);
  const again = activitySequence(31);
  const different = activitySequence(32);

  assert.ok(first.length > 12);
  assert.deepEqual(first, again);
  assert.notDeepEqual(first, different);
  first.forEach((activity, index) => assert.notEqual(activity, first[index - 1]));
});

test('daily activities run as coherent multi-stage flows', () => {
  const activities = createDailyActivities({ seed: 7, ...activeOptions });
  const stagesByActivity = new Map();

  for (let time = 0; time <= 1800; time += 0.5) {
    const sample = activities.update({
      time,
      currentAnchor: 0.3,
      context: { ...context, weather: 'rain' },
      propReady: true
    });
    if (!sample.activity || !sample.stage) continue;
    const stages = stagesByActivity.get(sample.activity) ?? [];
    if (stages.at(-1) !== sample.stage) stages.push(sample.stage);
    stagesByActivity.set(sample.activity, stages);
  }

  assert.deepEqual(stagesByActivity.get('tea-view')?.slice(0, 4), ['walk', 'drink', 'skyLook', 'rest-standing']);
  assert.deepEqual(stagesByActivity.get('music-break')?.slice(0, 4), ['walk', 'hum', 'dance', 'rest-standing']);
  assert.deepEqual(stagesByActivity.get('weather-watch')?.slice(0, 3), ['walk', 'skyLook', 'rest-standing']);
  assert.deepEqual(stagesByActivity.get('city-stroll')?.slice(0, 4), ['walk', 'lookAround', 'stretch', 'rest-standing']);
});

test('prop stages deliberately pick up and put away their activity prop', () => {
  const activities = createDailyActivities({ seed: 7, ...activeOptions });
  const samples = new Map();
  for (let time = 0; time <= 1800; time += 0.5) {
    const sample = activities.update({
      time,
      currentAnchor: 0.3,
      context: { ...context, weather: 'rain' },
      propReady: true
    });
    if (sample.activity && sample.stage) samples.set(`${sample.activity}:${sample.stage}`, sample);
  }

  assert.deepEqual(
    { ownsProp: samples.get('tea-view:walk').ownsProp, prop: samples.get('tea-view:walk').prop },
    { ownsProp: true, prop: null }
  );
  assert.deepEqual(
    { ownsProp: samples.get('tea-view:drink').ownsProp, prop: samples.get('tea-view:drink').prop },
    { ownsProp: true, prop: 'drink' }
  );
  assert.deepEqual(
    { ownsProp: samples.get('music-break:hum').ownsProp, prop: samples.get('music-break:hum').prop },
    { ownsProp: true, prop: 'listen' }
  );
});

test('an interruption freezes the current stage and resumes its remaining time', () => {
  const activities = createDailyActivities({ seed: 4, ...activeOptions });
  activities.update({ time: 0, currentAnchor: 0.25, context, propReady: true });
  const before = activities.update({ time: 1, currentAnchor: 0.25, context, propReady: true });

  const paused = activities.update({ time: 10, currentAnchor: 0.37, context, interrupted: true, propReady: true });
  assert.equal(paused.behavior, null);
  assert.equal(paused.anchor, 0.37);
  activities.update({ time: 30, currentAnchor: 0.25, context, interrupted: true, propReady: true });
  const resumed = activities.update({ time: 30.1, currentAnchor: 0.25, context, propReady: true });

  assert.equal(resumed.activity, before.activity);
  assert.equal(resumed.stage, before.stage);
  assert.ok(resumed.behavior.progress > before.behavior.progress);
  assert.ok(resumed.behavior.progress - before.behavior.progress < 0.08);
});

test('an interruption outside an activity leaves ordinary props under the existing routine', () => {
  const activities = createDailyActivities({ seed: 4, initialDelay: [20, 20] });
  const paused = activities.update({ time: 0, currentAnchor: 0.37, context, interrupted: true, propReady: true });

  assert.equal(paused.activity, null);
  assert.equal(paused.prop, undefined);
  assert.equal(paused.ownsProp, false);
});

test('call over puts away a held prop before walking near the user', () => {
  const activities = createDailyActivities({ seed: 11, ...activeOptions });
  activities.update({ time: 0, currentAnchor: 0.22, context, propReady: true });
  assert.equal(activities.callOver({ time: 1, currentAnchor: 0.22, targetAnchor: 0.5 }), true);

  const puttingAway = activities.update({ time: 1, currentAnchor: 0.22, context, propReady: false });
  assert.equal(puttingAway.calling, 'putAway');
  assert.equal(puttingAway.prop, null);
  assert.equal(puttingAway.behavior.name, 'idle');
  assert.equal(puttingAway.behavior.anchor, 0.22);

  const stillPuttingAway = activities.update({ time: 4, currentAnchor: 0.22, context, propReady: false });
  assert.equal(stillPuttingAway.calling, 'putAway');
  assert.equal(stillPuttingAway.behavior.name, 'idle');

  const walking = activities.update({ time: 4.1, currentAnchor: 0.22, context, propReady: true });
  assert.equal(walking.calling, 'walking');
  assert.equal(walking.behavior.name, 'walk');
  assert.equal(walking.behavior.fromAnchor, 0.22);
  assert.equal(walking.behavior.toAnchor, 0.5);
});

test('physical interaction pauses call-over walking and then continues it', () => {
  const activities = createDailyActivities({ seed: 12, ...activeOptions });
  activities.update({ time: 0, currentAnchor: 0.2, context, propReady: true });
  activities.callOver({ time: 0.5, currentAnchor: 0.2, targetAnchor: 0.5 });
  activities.update({ time: 0.5, currentAnchor: 0.2, context, propReady: true });
  const before = activities.update({ time: 1, currentAnchor: 0.2, context, propReady: true });

  activities.update({ time: 8, currentAnchor: 0.2, context, interrupted: true, propReady: true });
  activities.update({ time: 18, currentAnchor: 0.2, context, interrupted: true, propReady: true });
  const resumed = activities.update({ time: 18.1, currentAnchor: 0.2, context, propReady: true });

  assert.equal(resumed.calling, 'walking');
  assert.ok(resumed.behavior.progress > before.behavior.progress);
  assert.ok(resumed.behavior.progress - before.behavior.progress < 0.08);
});

test('safety priorities cancel autonomous movement', () => {
  for (const priority of ['sleep', 'angry', 'carried', 'dragged', 'reducedMotion']) {
    const activities = createDailyActivities({ seed: 20, ...activeOptions });
    activities.update({ time: 0, currentAnchor: 0.24, context, propReady: true });
    activities.callOver({ time: 0.5, currentAnchor: 0.24, targetAnchor: 0.5 });

    const cancelled = activities.update({ time: 1, currentAnchor: 0.24, context, priority, propReady: true });
    assert.equal(cancelled.activity, null, priority);
    assert.equal(cancelled.calling, null, priority);
    assert.equal(cancelled.behavior, null, priority);
    assert.equal(cancelled.prop, undefined, priority);
    assert.equal(cancelled.ownsProp, false, priority);
  }
});

test('manual positioning blocks daily movement but an explicit call can temporarily override it', () => {
  const activities = createDailyActivities({ seed: 20, ...activeOptions });
  activities.update({ time: 0, currentAnchor: 0.24, context, propReady: true });
  const pinned = activities.update({ time: 1, currentAnchor: 0.24, context, priority: 'pinned', propReady: true });
  assert.equal(pinned.activity, null);
  assert.equal(pinned.behavior, null);
  assert.equal(pinned.prop, undefined);
  assert.equal(pinned.ownsProp, false);

  assert.equal(activities.callOver({
    time: 1.1,
    currentAnchor: 0.24,
    targetAnchor: 0.5,
    priority: 'pinned'
  }), true);
  const called = activities.update({
    time: 1.1,
    currentAnchor: 0.24,
    context,
    priority: 'pinned',
    propReady: true
  });
  assert.equal(called.calling, 'walking');
  assert.equal(called.behavior.toAnchor, 0.5);
});

test('call over stays arrived during chat, walks back, then releases the paused activity', () => {
  const activities = createDailyActivities({ seed: 2, ...activeOptions });
  const original = activities.update({ time: 0, currentAnchor: 0.22, context, propReady: true });
  activities.callOver({ time: 0.5, currentAnchor: 0.22, targetAnchor: 0.5 });
  activities.update({ time: 0.5, currentAnchor: 0.22, context, propReady: true });
  const arrived = activities.update({ time: 10, currentAnchor: 0.5, context, engaged: true, propReady: true });

  assert.equal(arrived.arrived, true);
  assert.equal(arrived.calling, 'arrived');
  assert.equal(arrived.behavior.name, 'hello');
  assert.equal(activities.update({ time: 30, currentAnchor: 0.5, context, engaged: true, propReady: true }).calling, 'arrived');

  const waiting = activities.update({ time: 30.8, currentAnchor: 0.5, context, propReady: true });
  assert.equal(waiting.calling, 'arrived');
  assert.equal(waiting.behavior.name, 'idle');

  const returning = activities.update({ time: 38.1, currentAnchor: 0.5, context, propReady: true });
  assert.equal(returning.calling, 'returning');
  assert.equal(returning.behavior.name, 'walk');
  assert.equal(returning.behavior.fromAnchor, 0.5);
  assert.equal(returning.behavior.toAnchor, 0.22);

  const returningBeforeChat = activities.update({ time: 39.1, currentAnchor: 0.43, context, propReady: true });
  const pausedForChat = activities.update({ time: 45, currentAnchor: 0.43, context, engaged: true, propReady: true });
  const stillPaused = activities.update({ time: 55, currentAnchor: 0.43, context, engaged: true, propReady: true });
  const resumedReturn = activities.update({ time: 55.1, currentAnchor: 0.43, context, propReady: true });
  assert.equal(pausedForChat.behavior, null);
  assert.equal(pausedForChat.anchor, 0.43);
  assert.equal(stillPaused.anchor, 0.43);
  assert.equal(resumedReturn.calling, 'returning');
  assert.ok(resumedReturn.behavior.progress > returningBeforeChat.behavior.progress);
  assert.ok(resumedReturn.behavior.progress - returningBeforeChat.behavior.progress < 0.08);

  activities.update({ time: 65, currentAnchor: 0.22, context, propReady: true });
  const resumed = activities.update({ time: 65.1, currentAnchor: 0.22, context, propReady: true });
  assert.equal(resumed.activity, original.activity);
  assert.notEqual(resumed.behavior, null);
});

test('activity completion exposes its final anchor for a continuous routine handoff', () => {
  const activities = createDailyActivities({
    seed: 8,
    initialDelay: [0, 0],
    betweenDelay: [20, 20]
  });
  let previous = activities.update({ time: 0, currentAnchor: 0.28, context, propReady: true });
  let completed = null;
  for (let time = 0.5; time < 80; time += 0.5) {
    const sample = activities.update({ time, currentAnchor: previous.anchor ?? 0.28, context, propReady: true });
    if (previous.activity && !sample.activity) {
      completed = sample;
      break;
    }
    previous = sample;
  }

  assert.ok(Number.isFinite(completed?.completedAnchor));
  assert.equal(completed.anchor, completed.completedAnchor);
  assert.equal(completed.behavior, null);
});

test('rain activity is only eligible in outdoor scenes', () => {
  const activities = createDailyActivities({ seed: 19, ...activeOptions });
  const seen = new Set();
  for (let time = 0; time < 1200; time += 1) {
    const sample = activities.update({
      time,
      currentAnchor: 0.3,
      context: { ...context, scene: 'room', weather: 'rain', musicPlaying: false },
      propReady: true
    });
    if (sample.activity) seen.add(sample.activity);
  }

  assert.equal(seen.has('weather-watch'), false);
  assert.ok(seen.has('tea-view'));
  assert.ok(seen.has('city-stroll'));
});
