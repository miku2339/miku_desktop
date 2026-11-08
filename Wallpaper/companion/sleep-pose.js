// Asleep in bed, alive: breathing you can see, a change of position now and then, a nuzzle into
// the pillow, sleepy z's at an uneven pace, and a stir that starts gently when you touch her.
//
// Only the upper body, arms and head change: her legs stay as calibrated under the blanket
// picture (room-blanket-*.png), so nothing pokes out of it.

/** Upper-body poses she shifts between, per side ([x, y, z] bone rotations, radians). */
export const SLEEP_POSES = [
  {
    // Curled up, hands together in front of her chest.
    name: 'curled',
    spine: 0.12,
    neck: [0.08, 0, 0.05],
    head: [0.06, 0.05, 0.12],
    arms: {
      左: { 腕: [0, -0.85, 0.2], ひじ: [0, -1.7, 0], 手首: [0, 0, 0.3] },
      右: { 腕: [0, 0.85, -0.2], ひじ: [0, 1.7, 0], 手首: [0, 0, -0.3] }
    }
  },
  {
    // One hand drawn up by her face, the other resting in front of her.
    name: 'nearFace',
    spine: 0.15,
    neck: [0.1, 0, 0.07],
    head: [0.09, 0.08, 0.16],
    arms: {
      左: { 腕: [0, -0.95, 0.95], ひじ: [0, -1.95, 0], 手首: [0, 0, 0.4] },
      右: { 腕: [0, 0.75, -0.15], ひじ: [0, 1.5, 0], 手首: [0, 0, -0.25] }
    }
  },
  {
    // Loosened in deeper sleep: arms relaxed, head sunk a little further.
    name: 'relaxed',
    spine: 0.09,
    neck: [0.06, 0, 0.08],
    head: [0.03, 0.02, 0.15],
    arms: {
      左: { 腕: [0, -0.62, 0.1], ひじ: [0, -1.25, 0], 手首: [0, 0, 0.15] },
      右: { 腕: [0, 0.6, -0.08], ひじ: [0, 1.2, 0], 手首: [0, 0, -0.15] }
    }
  }
];

export const SHIFT_SECONDS = 2.4;
export const NUZZLE_SECONDS = 1.4;

const smootherstep = t => {
  const x = Math.min(1, Math.max(0, t));
  return x * x * x * (x * (x * 6 - 15) + 10);
};
const lerp = (a, b, t) => a + (b - a) * t;
const lerp3 = (a, b, t) => [lerp(a[0], b[0], t), lerp(a[1], b[1], t), lerp(a[2], b[2], t)];

/** A pose part way from one to another (t 0..1), for a slow shift that never snaps. */
export function blendPoses(from, to, t) {
  const arms = {};
  for (const side of Object.keys(from.arms)) {
    arms[side] = {};
    for (const bone of Object.keys(from.arms[side])) {
      arms[side][bone] = lerp3(from.arms[side][bone], to.arms[side][bone], t);
    }
  }
  return {
    spine: lerp(from.spine, to.spine, t),
    neck: lerp3(from.neck, to.neck, t),
    head: lerp3(from.head, to.head, t),
    arms
  };
}

/**
 * How strongly she stirs `since` seconds after a touch: eases in over 0.3 s, then fades over
 * 1.6 s. 0 before the touch and once it has passed.
 */
export function stirEnvelope(since) {
  if (!Number.isFinite(since) || since < 0) return 0;
  if (since < 0.3) return smootherstep(since / 0.3);
  return Math.max(0, 1 - (since - 0.3) / 1.6);
}

/**
 * The sleeping body over time. `step(t)` (t in seconds, always increasing) returns the pose to
 * apply, the breath (-1..1), the nuzzle (0..1) and whether a "z" floats up this frame.
 */
export function createSleepPoser(random = Math.random) {
  let pose = 0;
  let from = 0;
  let shiftStart = -Infinity;
  let nextShift = null;
  let nuzzleStart = -Infinity;
  let nextNuzzle = null;
  let nextZ = null;
  let breathPhase = 0;
  let lastT = null;

  const between = (low, high) => low + random() * (high - low);

  function reset(t, startPose = 0) {
    pose = from = startPose;
    shiftStart = -Infinity;
    nextShift = t + between(240, 660);
    nuzzleStart = -Infinity;
    nextNuzzle = t + between(60, 180);
    nextZ = t + between(0.8, 2);
    breathPhase = 0;
    lastT = t;
  }

  function step(t) {
    if (lastT === null || t < lastT) reset(t);
    const dt = Math.min(0.25, t - lastT);
    lastT = t;

    // Breathing: about 4.3 s a breath, drifting a little so it never ticks like a metronome.
    const period = 4.3 + 0.4 * Math.sin(t * 0.05);
    breathPhase = (breathPhase + dt / period) % 1;
    const breath = Math.sin(breathPhase * Math.PI * 2);

    // Now and then she turns a little into another position.
    if (t >= nextShift && t - shiftStart >= SHIFT_SECONDS) {
      from = pose;
      const choices = SLEEP_POSES.map((_, index) => index).filter(index => index !== pose);
      pose = choices[Math.floor(random() * choices.length) % choices.length];
      shiftStart = t;
      nextShift = t + between(240, 660);
    }
    const shift = smootherstep((t - shiftStart) / SHIFT_SECONDS);
    const blended = blendPoses(SLEEP_POSES[from], SLEEP_POSES[pose], shift);

    // A nuzzle into the pillow: a soft bump up and back down.
    if (t >= nextNuzzle) {
      nuzzleStart = t;
      nextNuzzle = t + between(60, 180);
    }
    const nuzzleT = (t - nuzzleStart) / NUZZLE_SECONDS;
    const nuzzle = nuzzleT >= 0 && nuzzleT <= 1 ? Math.sin(nuzzleT * Math.PI) : 0;

    // Sleepy z's at an uneven pace.
    let z = false;
    if (t >= nextZ) {
      z = true;
      nextZ = t + between(1.4, 3.6);
    }

    return { pose: blended, poseName: SLEEP_POSES[pose].name, shifting: shift < 1, breath, nuzzle, z };
  }

  return { step, reset };
}
