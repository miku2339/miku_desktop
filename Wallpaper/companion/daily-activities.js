import { createVariety, mulberry32 } from './variety.js';

const DEFAULT_INITIAL_DELAY = [18, 42];
const DEFAULT_BETWEEN_DELAY = [55, 130];
const CALL_ARRIVAL_DWELL = 8;
const CANCEL_PRIORITIES = new Set(['sleep', 'angry', 'carried', 'dragged', 'pinned', 'reducedMotion']);

const ACTIVITY_PLANS = {
  'tea-view': [
    { stage: 'walk', behavior: 'walk', duration: 4.5, prop: null },
    { stage: 'drink', behavior: 'idle', duration: 8, prop: 'drink' },
    { stage: 'skyLook', behavior: 'skyLook', duration: 5.5 },
    { stage: 'rest-standing', behavior: 'rest-standing', duration: 6 }
  ],
  'music-break': [
    { stage: 'walk', behavior: 'walk', duration: 4, prop: null },
    { stage: 'hum', behavior: 'hum', duration: 7, prop: 'listen' },
    { stage: 'dance', behavior: 'dance', duration: 7.5 },
    { stage: 'rest-standing', behavior: 'rest-standing', duration: 5.5 }
  ],
  'weather-watch': [
    { stage: 'walk', behavior: 'walk', duration: 4.5 },
    { stage: 'skyLook', behavior: 'skyLook', duration: 6 },
    { stage: 'rest-standing', behavior: 'rest-standing', duration: 7 }
  ],
  'city-stroll': [
    { stage: 'walk', behavior: 'walk', duration: 5, prop: null },
    { stage: 'lookAround', behavior: 'lookAround', duration: 5, prop: null },
    { stage: 'stretch', behavior: 'stretch', duration: 5.5 },
    { stage: 'rest-standing', behavior: 'rest-standing', duration: 5 }
  ]
};

const clamp = (value, minimum, maximum) => Math.min(maximum, Math.max(minimum, value));

function validRange(value, fallback) {
  if (!Array.isArray(value) || value.length !== 2) return fallback;
  const minimum = Number(value[0]);
  const maximum = Number(value[1]);
  if (!Number.isFinite(minimum) || !Number.isFinite(maximum) || minimum < 0 || maximum < minimum) return fallback;
  return [minimum, maximum];
}

export function createDailyActivities({
  seed = Date.now(),
  minAnchor = 0.2,
  maxAnchor = 0.64,
  initialDelay = DEFAULT_INITIAL_DELAY,
  betweenDelay = DEFAULT_BETWEEN_DELAY
} = {}) {
  const variety = createVariety(mulberry32(seed));
  const firstDelay = validRange(initialDelay, DEFAULT_INITIAL_DELAY);
  const repeatDelay = validRange(betweenDelay, DEFAULT_BETWEEN_DELAY);
  const minimumAnchor = Number.isFinite(minAnchor) ? minAnchor : 0.2;
  const maximumAnchor = Number.isFinite(maxAnchor) && maxAnchor > minimumAnchor ? maxAnchor : 0.64;
  let clock = 0;
  let lastTime = null;
  let nextStart = variety.range(...firstDelay);
  let active = null;
  let call = null;
  let lastActivity = null;
  let lastPriority = null;
  let lastKnownAnchor = minimumAnchor;
  let completedAnchor = null;

  function neutral({ putAway = false, anchor = lastKnownAnchor } = {}) {
    return {
      activity: active?.id ?? null,
      stage: active ? ACTIVITY_PLANS[active.id][active.stageIndex].stage : null,
      behavior: null,
      anchor,
      prop: putAway ? null : undefined,
      ownsProp: putAway,
      calling: call?.phase ?? null,
      arrived: call?.phase === 'arrived'
    };
  }

  function emit(output) {
    const result = { ...output, completedAnchor };
    completedAnchor = null;
    return result;
  }

  function activityChoices(context) {
    const weather = context?.weather;
    const music = Boolean(context?.musicPlaying);
    const hour = Number(context?.hour);
    const scene = context?.scene;
    const teaTime = Number.isFinite(hour) && hour >= 12 && hour < 18;
    const indoors = scene === 'room' || scene === 'hallway' || scene === 'musicroom';
    const choices = [
      { id: 'tea-view', weight: teaTime || indoors ? 2.2 : 0.8 },
      { id: 'music-break', weight: music ? (scene === 'musicroom' ? 5 : 3.4) : 0 },
      { id: 'weather-watch', weight: !indoors && (weather === 'rain' || weather === 'snow') ? 3.2 : 0 },
      { id: 'city-stroll', weight: 1.6 }
    ];
    const available = choices.filter(choice => choice.weight > 0 && choice.id !== lastActivity);
    return available.length ? available : choices.filter(choice => choice.weight > 0);
  }

  function destinationFrom(anchor) {
    const current = clamp(Number(anchor) || minimumAnchor, minimumAnchor, maximumAnchor);
    for (let attempt = 0; attempt < 8; attempt += 1) {
      const destination = variety.range(minimumAnchor, maximumAnchor);
      if (Math.abs(destination - current) >= 0.1) return destination;
    }
    return current < (minimumAnchor + maximumAnchor) / 2 ? maximumAnchor : minimumAnchor;
  }

  function startActivity(currentAnchor, context) {
    const choices = activityChoices(context);
    const id = variety.pick('daily-activity', choices);
    if (!id) return;
    const anchor = clamp(Number(currentAnchor) || minimumAnchor, minimumAnchor, maximumAnchor);
    active = {
      id,
      stageIndex: 0,
      stageElapsed: 0,
      anchor,
      destination: destinationFrom(anchor),
      flip: variety.chance(0.5) ? 1 : -1,
      side: variety.chance(0.5) ? '左' : '右'
    };
    lastActivity = id;
  }

  function finishActivity() {
    completedAnchor = active?.destination ?? lastKnownAnchor;
    lastKnownAnchor = completedAnchor;
    active = null;
    nextStart = clock + variety.range(...repeatDelay);
  }

  function advanceActivity(delta) {
    let remaining = delta;
    while (active && remaining > 0) {
      const stage = ACTIVITY_PLANS[active.id][active.stageIndex];
      const left = stage.duration - active.stageElapsed;
      if (remaining < left) {
        active.stageElapsed += remaining;
        return;
      }
      remaining -= left;
      active.stageIndex += 1;
      active.stageElapsed = 0;
      active.anchor = active.destination;
      if (active.stageIndex >= ACTIVITY_PLANS[active.id].length) finishActivity();
    }
  }

  function activityResult() {
    if (!active) return neutral();
    const stage = ACTIVITY_PLANS[active.id][active.stageIndex];
    const progress = clamp(active.stageElapsed / stage.duration, 0, 1);
    const walking = stage.behavior === 'walk';
    const behavior = {
      name: stage.behavior,
      progress,
      duration: stage.duration,
      fromAnchor: walking ? active.anchor : active.destination,
      toAnchor: active.destination,
      anchor: active.destination,
      activity: active.id,
      variant: {
        speed: 1,
        amplitude: 1,
        side: active.side,
        flip: active.flip,
        style: null,
        talk: false
      }
    };
    const ownsProp = Object.hasOwn(stage, 'prop');
    return {
      activity: active.id,
      stage: stage.stage,
      behavior,
      anchor: lastKnownAnchor,
      prop: ownsProp ? stage.prop : undefined,
      ownsProp,
      calling: null,
      arrived: false
    };
  }

  function callResult() {
    if (!call) return neutral();
    if (call.phase === 'putAway') {
      return {
        ...neutral({ putAway: true }),
        behavior: {
          name: 'idle',
          progress: 0,
          duration: 1,
          fromAnchor: call.fromAnchor,
          toAnchor: call.fromAnchor,
          anchor: call.fromAnchor,
          activity: 'call-over'
        }
      };
    }
    if (call.phase === 'walking') {
      const progress = clamp(call.elapsed / call.duration, 0, 1);
      return {
        ...neutral({ putAway: true }),
        behavior: {
          name: 'walk',
          progress,
          duration: call.duration,
          fromAnchor: call.fromAnchor,
          toAnchor: call.targetAnchor,
          anchor: call.targetAnchor,
          activity: 'call-over',
          variant: { speed: 1, amplitude: 1, side: '左', flip: 1, style: null, talk: false }
        }
      };
    }
    if (call.phase === 'returning') {
      const progress = clamp(call.elapsed / call.returnDuration, 0, 1);
      return {
        ...neutral({ putAway: true }),
        behavior: {
          name: 'walk',
          progress,
          duration: call.returnDuration,
          fromAnchor: call.targetAnchor,
          toAnchor: call.resumeAnchor,
          anchor: call.resumeAnchor,
          activity: 'call-over',
          variant: { speed: 1, amplitude: 1, side: '右', flip: -1, style: null, talk: false }
        }
      };
    }
    if (call.releaseElapsed >= 0.75) {
      return {
        ...neutral({ putAway: true, anchor: call.targetAnchor }),
        behavior: {
          name: 'idle',
          progress: 0,
          duration: CALL_ARRIVAL_DWELL,
          fromAnchor: call.targetAnchor,
          toAnchor: call.targetAnchor,
          anchor: call.targetAnchor,
          activity: 'call-over'
        }
      };
    }
    return {
      ...neutral({ putAway: true }),
      behavior: {
        name: 'hello',
        progress: clamp(call.releaseElapsed / 0.75, 0, 1),
        duration: 0.75,
        fromAnchor: call.targetAnchor,
        toAnchor: call.targetAnchor,
        anchor: call.targetAnchor,
        activity: 'call-over',
        variant: { speed: 1, amplitude: 1, side: '左', flip: 1, style: null, talk: false }
      }
    };
  }

  function cancelAutomatic() {
    active = null;
    call = null;
    nextStart = clock + variety.range(...repeatDelay);
  }

  function update({
    time,
    currentAnchor = minimumAnchor,
    context = {},
    interrupted = false,
    engaged = false,
    priority = null,
    propReady = true
  } = {}) {
    const now = Number(time);
    if (!Number.isFinite(now) || (lastTime !== null && now < lastTime)) return call ? callResult() : activityResult();
    const delta = lastTime === null ? 0 : now - lastTime;
    lastTime = now;
    lastKnownAnchor = clamp(Number(currentAnchor) || minimumAnchor, minimumAnchor, maximumAnchor);

    if (CANCEL_PRIORITIES.has(priority) && !(priority === 'pinned' && call)) {
      if (priority !== lastPriority || active || call) cancelAutomatic();
      lastPriority = priority;
      return emit(neutral());
    }
    lastPriority = null;

    if (call) {
      if (interrupted || (engaged && call.phase === 'returning')) return emit(neutral({ putAway: true }));
      if (call.phase === 'putAway') {
        if (!propReady) return emit(callResult());
        call.phase = 'walking';
        call.elapsed = 0;
        call.fromAnchor = lastKnownAnchor;
      } else if (call.phase === 'walking') {
        call.elapsed += delta;
        if (call.elapsed >= call.duration) {
          call.phase = 'arrived';
          call.releaseElapsed = 0;
        }
      } else if (call.phase === 'arrived' && !engaged) {
        call.releaseElapsed += delta;
        if (call.releaseElapsed >= CALL_ARRIVAL_DWELL) {
          if (Math.abs(call.targetAnchor - call.resumeAnchor) > 0.01) {
            call.phase = 'returning';
            call.elapsed = 0;
          } else call = null;
        }
      } else if (call.phase === 'returning') {
        call.elapsed += delta;
        if (call.elapsed >= call.returnDuration) {
          lastKnownAnchor = call.resumeAnchor;
          if (!active) completedAnchor = call.resumeAnchor;
          call = null;
        }
      }
      return emit(call ? callResult() : activityResult());
    }

    if (interrupted || engaged) return emit(neutral({ putAway: Boolean(active) }));
    clock += delta;
    if (active) advanceActivity(delta);
    if (!active && clock >= nextStart) startActivity(currentAnchor, context);
    return emit(activityResult());
  }

  function callOver({ time, currentAnchor = minimumAnchor, targetAnchor = 0.5, priority = null } = {}) {
    if (CANCEL_PRIORITIES.has(priority) && priority !== 'pinned') return false;
    const now = Number(time);
    if (Number.isFinite(now) && (lastTime === null || now >= lastTime)) lastTime = now;
    const fromAnchor = clamp(Number(currentAnchor) || minimumAnchor, minimumAnchor, maximumAnchor);
    const target = clamp(Number(targetAnchor) || 0.5, minimumAnchor, maximumAnchor);
    const distance = Math.abs(target - fromAnchor);
    call = {
      phase: 'putAway',
      fromAnchor,
      targetAnchor: target,
      resumeAnchor: fromAnchor,
      elapsed: 0,
      releaseElapsed: 0,
      duration: clamp(1.8 + distance * 8, 1.8, 4.8),
      returnDuration: clamp(1.8 + distance * 8, 1.8, 4.8)
    };
    return true;
  }

  function reset() {
    clock = 0;
    lastTime = null;
    active = null;
    call = null;
    lastActivity = null;
    lastPriority = null;
    lastKnownAnchor = minimumAnchor;
    completedAnchor = null;
    nextStart = variety.range(...firstDelay);
  }

  return { update, callOver, reset };
}
