// Shake detection while Miku is being carried.
//
// Dragging her somewhere is fine; whipping the pointer back and forth is not. Each sharp
// change of direction at speed adds to `dizziness` (0..1), which drains away over a few
// seconds. `peak` remembers the worst of it for the current carry so the reaction after
// she is put down can match how hard she was shaken.

const MIN_SPEED = 0.55; // screen heights / widths per second before a reversal counts
const REVERSAL_GAP = 0.05; // seconds; ignore jitter faster than this
const SMOOTHING = 0.035; // seconds; velocity low-pass time constant
const DECAY_HELD = 0.32; // per second, while still being held
const DECAY_FREE = 0.55; // per second, once released
const WINDOW = 0.9;
const TURN_SPEED = 0.15; // speed the new direction must reach before it counts as a turn // seconds of reversals that count as "currently shaking"

const clamp = (value, minimum, maximum) => Math.min(maximum, Math.max(minimum, value));

const freshLegs = () => ({ x: { sign: 0, peak: 0 }, y: { sign: 0, peak: 0 } });

export function createShake() {
  let last = null;
  let velocity = { x: 0, y: 0 };
  let lastReversal = { x: -Infinity, y: -Infinity };
  let legs = freshLegs();
  let reversals = [];
  let dizziness = 0;
  let peak = 0;
  let total = 0;
  let lastTime = null;
  let held = false;

  function decayTo(time) {
    if (lastTime === null || !Number.isFinite(time)) {
      lastTime = time;
      return;
    }
    const delta = Math.max(0, time - lastTime);
    lastTime = Math.max(lastTime, time);
    dizziness *= Math.exp(-(held ? DECAY_HELD : DECAY_FREE) * delta);
    if (dizziness < 1e-4) dizziness = 0;
  }

  function snapshot(time = lastTime) {
    const recent = reversals.filter(stamp => time - stamp <= WINDOW).length;
    return { dizziness, peak, reversals: total, shaking: recent >= 2, held };
  }

  function begin(time) {
    held = true;
    last = null;
    velocity = { x: 0, y: 0 };
    lastReversal = { x: -Infinity, y: -Infinity };
    legs = freshLegs();
    reversals = [];
    total = 0;
    peak = dizziness;
    lastTime = Number.isFinite(time) ? time : lastTime;
    return snapshot(time);
  }

  function sample({ x, y, time } = {}) {
    if (!held || ![x, y, time].every(Number.isFinite)) return snapshot();
    if (last && time <= last.time) return snapshot();
    decayTo(time);
    if (!last) {
      last = { x, y, time };
      return snapshot(time);
    }
    const delta = time - last.time;
    const raw = { x: (x - last.x) / delta, y: (y - last.y) / delta };
    const blend = 1 - Math.exp(-delta / SMOOTHING);
    const next = {
      x: velocity.x + (raw.x - velocity.x) * blend,
      y: velocity.y + (raw.y - velocity.y) * blend
    };
    for (const axis of ['x', 'y']) {
      // A reversal happens when the pointer heads back the other way after a fast leg.
      // (At the turning point itself the speed is ~0, so judge the leg that just ended.)
      const speed = Math.abs(next[axis]);
      const direction = Math.sign(next[axis]);
      const leg = legs[axis];
      if (speed > TURN_SPEED && direction !== leg.sign) {
        if (leg.sign !== 0 && leg.peak > MIN_SPEED && time - lastReversal[axis] > REVERSAL_GAP) {
          lastReversal[axis] = time;
          reversals.push(time);
          total += 1;
          // Harder, faster whips make her dizzier; a lazy wobble barely registers.
          const force = clamp(leg.peak / 1.6, 0.35, 1.6);
          dizziness = clamp(dizziness + 0.085 * force, 0, 1);
        }
        leg.sign = direction;
        leg.peak = speed;
      } else if (direction === leg.sign) {
        leg.peak = Math.max(leg.peak, speed);
      }
    }
    reversals = reversals.filter(stamp => time - stamp <= WINDOW);
    velocity = next;
    last = { x, y, time };
    peak = Math.max(peak, dizziness);
    return snapshot(time);
  }

  function release(time) {
    decayTo(time);
    held = false;
    last = null;
    velocity = { x: 0, y: 0 };
    return snapshot(time);
  }

  function update(time) {
    decayTo(time);
    return snapshot(time);
  }

  function reset() {
    last = null;
    velocity = { x: 0, y: 0 };
    lastReversal = { x: -Infinity, y: -Infinity };
    legs = freshLegs();
    reversals = [];
    dizziness = 0;
    peak = 0;
    total = 0;
    lastTime = null;
    held = false;
    return snapshot(0);
  }

  return { begin, sample, release, update, reset, status: () => snapshot() };
}

/**
 * Picks how she reacts once she's back on her feet.
 * `recentShakes` counts earlier hard shakes in the last couple of minutes, so being
 * shaken again and again moves her from dizzy, to cross, to giving you the cold shoulder.
 */
export function shakeAftermath({ peak = 0, recentShakes = 0, impact = 0, mood = 0, random = Math.random } = {}) {
  if (peak >= 0.3) {
    if (recentShakes >= 2) return { type: 'dizzy', style: 'sulk', duration: 7.5 };
    if (recentShakes === 1) return { type: 'dizzy', style: 'pout', duration: 4 + peak * 2.4 };
    const style = peak < 0.55 && random() < 0.4 + mood * 0.2 ? 'giggle' : 'recover';
    return { type: 'dizzy', style, duration: 2.8 + peak * 3.2 };
  }
  if (impact >= 0.55) return { type: 'ouch', style: random() < 0.5 ? 'bottom' : 'head', duration: 2.6 + impact };
  return null;
}
