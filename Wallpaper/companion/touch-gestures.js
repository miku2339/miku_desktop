const JITTER_DISTANCE = 0.002;
const MIN_SEGMENT_DISTANCE = 0.005;
const MIN_STROKE_DISTANCE = 0.02;
const FULL_INTENSITY_DISTANCE = 0.06;
const MAX_SAMPLE_GAP = 0.25;
const COOLDOWN_SECONDS = 0.8;

const clamp01 = value => Math.min(1, Math.max(0, value));

export function createTouchGestures() {
  let lastX = null;
  let lastTime = null;
  let direction = 0;
  let segmentDistance = 0;
  let strokeDistance = 0;
  let reversalPending = false;
  let hasReversal = false;
  let lastEmissionTime = Number.NEGATIVE_INFINITY;

  function resetTracking() {
    lastX = null;
    lastTime = null;
    direction = 0;
    segmentDistance = 0;
    strokeDistance = 0;
    reversalPending = false;
    hasReversal = false;
  }

  function reset() {
    resetTracking();
    lastEmissionTime = Number.NEGATIVE_INFINITY;
  }

  function start(x, time) {
    lastX = x;
    lastTime = time;
  }

  function sample({ zone, x, y, time, pressed = false } = {}) {
    const validCoordinates = Number.isFinite(x)
      && Number.isFinite(y)
      && x >= 0
      && x <= 1
      && y >= 0
      && y <= 1;
    if (zone !== 'head' || pressed || !validCoordinates || !Number.isFinite(time)) {
      resetTracking();
      return null;
    }

    if (lastTime !== null && time < lastTime) {
      resetTracking();
      return null;
    }
    if (lastTime === null || time - lastTime > MAX_SAMPLE_GAP) {
      resetTracking();
      start(x, time);
      return null;
    }

    const deltaX = x - lastX;
    lastTime = time;
    if (Math.abs(deltaX) < JITTER_DISTANCE) return null;

    const nextDirection = Math.sign(deltaX);
    const distance = Math.abs(deltaX);
    lastX = x;
    strokeDistance += distance;

    if (direction === 0) {
      direction = nextDirection;
      segmentDistance = distance;
    } else if (nextDirection === direction) {
      segmentDistance += distance;
    } else {
      reversalPending = segmentDistance >= MIN_SEGMENT_DISTANCE;
      direction = nextDirection;
      segmentDistance = distance;
    }

    if (reversalPending && segmentDistance >= MIN_SEGMENT_DISTANCE) {
      hasReversal = true;
      reversalPending = false;
    }

    if (!hasReversal || strokeDistance < MIN_STROKE_DISTANCE) return null;

    const canEmit = time - lastEmissionTime >= COOLDOWN_SECONDS;
    const intensity = clamp01(strokeDistance / FULL_INTENSITY_DISTANCE);
    resetTracking();
    start(x, time);
    if (!canEmit) return null;

    lastEmissionTime = time;
    return { type: 'headStroke', intensity };
  }

  return {
    sample,
    reset
  };
}
