const GRAVITY = 18;
const HELD_FREQUENCY = 18;
const LANDING_SECONDS = 0.55;
const MAX_THROW_SPEED = 8;
const MAX_DELTA = 0.1;
const EPSILON = 1e-6;

const clamp = (value, minimum, maximum) => Math.min(maximum, Math.max(minimum, value));

export function createCarry({ maxHeight = 6 } = {}) {
  const ceiling = Number.isFinite(maxHeight) && maxHeight > 0 ? maxHeight : 6;
  let phase = 'idle';
  let height = 0;
  let velocity = 0;
  let sway = 0;
  let targetHeight = 0;
  let grabHeight = 0;
  let grabPointerY = 0;
  let lastPointerY = 0;
  let lastPointerTime = null;
  let pointerVelocity = 0;
  let lastTime = null;
  let landingElapsed = 0;

  function snapshot(impact = 0) {
    const result = { phase, height, velocity, sway };
    if (phase === 'landing') {
      result.landingProgress = clamp(landingElapsed / LANDING_SECONDS, 0, 1);
      result.compression = Math.sin(Math.PI * result.landingProgress);
    }
    if (impact > 0) result.impact = impact;
    return result;
  }

  function reset() {
    phase = 'idle';
    height = 0;
    velocity = 0;
    sway = 0;
    targetHeight = 0;
    grabHeight = 0;
    grabPointerY = 0;
    lastPointerY = 0;
    lastPointerTime = null;
    pointerVelocity = 0;
    lastTime = null;
    landingElapsed = 0;
    return snapshot();
  }

  function integrateHeld(delta) {
    const offset = height - targetHeight;
    const change = (velocity + HELD_FREQUENCY * offset) * delta;
    const decay = Math.exp(-HELD_FREQUENCY * delta);
    height = targetHeight + (offset + change) * decay;
    velocity = clamp((velocity - HELD_FREQUENCY * change) * decay, -MAX_THROW_SPEED, MAX_THROW_SPEED);
    height = clamp(height, 0, ceiling);
    pointerVelocity *= Math.exp(-12 * delta);
    sway = clamp(velocity / MAX_THROW_SPEED, -1, 1);
  }

  function integrateFalling(delta) {
    const nextHeight = height + velocity * delta - 0.5 * GRAVITY * delta * delta;
    if (nextHeight > 0) {
      height = nextHeight;
      velocity = Math.max(-MAX_THROW_SPEED, velocity - GRAVITY * delta);
      sway *= Math.exp(-5 * delta);
      return 0;
    }

    const impactSpeed = Math.sqrt(Math.max(0, velocity * velocity + 2 * GRAVITY * height));
    phase = 'landing';
    height = 0;
    velocity = 0;
    sway = 0;
    landingElapsed = 0;
    return clamp(impactSpeed / 10, 0, 1);
  }

  function integrateLanding(delta) {
    landingElapsed = Math.min(LANDING_SECONDS, landingElapsed + delta);
    if (landingElapsed >= LANDING_SECONDS - EPSILON) {
      phase = 'idle';
      landingElapsed = 0;
    }
  }

  function advance(time) {
    if (!Number.isFinite(time) || (lastTime !== null && time < lastTime)) return 0;
    if (lastTime === null) {
      lastTime = time;
      return 0;
    }
    const delta = clamp(time - lastTime, 0, MAX_DELTA);
    lastTime = time;
    if (delta <= 0) return 0;
    if (phase === 'held') integrateHeld(delta);
    else if (phase === 'falling') return integrateFalling(delta);
    else if (phase === 'landing') integrateLanding(delta);
    return 0;
  }

  function begin({ pointerY, time } = {}) {
    if (
      !Number.isFinite(pointerY)
      || !Number.isFinite(time)
      || (lastTime !== null && time < lastTime)
    ) return snapshot();
    advance(time);
    phase = 'held';
    grabHeight = height;
    grabPointerY = pointerY;
    lastPointerY = pointerY;
    lastPointerTime = time;
    pointerVelocity = 0;
    targetHeight = height;
    velocity = 0;
    sway = 0;
    landingElapsed = 0;
    lastTime = time;
    return snapshot();
  }

  function move({ pointerY, time } = {}) {
    if (phase !== 'held' || !Number.isFinite(pointerY) || !Number.isFinite(time)) return snapshot();
    if (
      (lastTime !== null && time < lastTime)
      || (lastPointerTime !== null && time < lastPointerTime)
    ) return snapshot();
    advance(time);
    const pointerDelta = pointerY - lastPointerY;
    const timeDelta = time - lastPointerTime;
    if (timeDelta > 0) {
      pointerVelocity = clamp(pointerDelta / timeDelta, -MAX_THROW_SPEED, MAX_THROW_SPEED);
    }
    lastPointerY = pointerY;
    lastPointerTime = time;
    targetHeight = clamp(grabHeight + pointerY - grabPointerY, 0, ceiling);
    return snapshot();
  }

  function release({ time } = {}) {
    if (phase !== 'held' || !Number.isFinite(time) || (lastTime !== null && time < lastTime)) return snapshot();
    advance(time);
    const throwVelocity = clamp(velocity * 0.65 + pointerVelocity * 0.35, -MAX_THROW_SPEED, MAX_THROW_SPEED);
    if (height <= EPSILON && throwVelocity <= EPSILON) return reset();
    phase = 'falling';
    velocity = throwVelocity;
    pointerVelocity = 0;
    return snapshot();
  }

  function update({ time, reducedMotion = false } = {}) {
    if (reducedMotion) return reset();
    const impact = advance(time);
    return snapshot(impact);
  }

  function status() {
    return snapshot();
  }

  return { begin, move, release, update, reset, status };
}
