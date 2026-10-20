// Variety: every reaction, idle moment and line comes out a little different.
//
// - pick(): weighted choice that never repeats the previous pick for the same key
// - line(): shuffle-bag phrases, so a line only comes back after the others were used
// - mood(): recent touches make her go from pleased to shy to teasing
// - createRoutine(): a seeded, open-ended idle routine instead of a fixed loop

export function mulberry32(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export function createVariety(random = Math.random) {
  const lastPick = new Map();
  const bags = new Map();
  const lastLine = new Map();
  let touches = [];

  function range(min, max) {
    return min + random() * (max - min);
  }

  function chance(probability) {
    return random() < probability;
  }

  /** options: array of { id, weight? } (or strings). Avoids repeating the last choice for this key. */
  function pick(key, options, weights = {}) {
    const list = options.map(option => (typeof option === 'string' ? { id: option } : option));
    if (list.length === 0) return null;
    const previous = lastPick.get(key);
    const pool = list.length > 1 ? list.filter(option => option.id !== previous) : list;
    const total = pool.reduce((sum, option) => sum + Math.max(0, weights[option.id] ?? option.weight ?? 1), 0);
    let roll = random() * (total || 1);
    let choice = pool[pool.length - 1];
    for (const option of pool) {
      roll -= Math.max(0, weights[option.id] ?? option.weight ?? 1);
      if (roll <= 0) {
        choice = option;
        break;
      }
    }
    lastPick.set(key, choice.id);
    return choice.id;
  }

  /** Shuffle-bag: every line is used once before any repeats, and never twice in a row. */
  function line(key, lines) {
    if (!lines?.length) return '';
    let bag = bags.get(key);
    if (!bag || bag.length === 0 || bag.source !== lines) {
      bag = [...lines];
      for (let index = bag.length - 1; index > 0; index -= 1) {
        const swap = Math.floor(random() * (index + 1));
        [bag[index], bag[swap]] = [bag[swap], bag[index]];
      }
      if (bag.length > 1 && bag[bag.length - 1] === lastLine.get(key)) {
        [bag[0], bag[bag.length - 1]] = [bag[bag.length - 1], bag[0]];
      }
      bag.source = lines;
      bags.set(key, bag);
    }
    const value = bag.pop();
    lastLine.set(key, value);
    return value;
  }

  /** Record a touch and return how "touched out" she is: 0 calm … 1 very attention-saturated. */
  function noteTouch(time) {
    touches = touches.filter(stamp => time - stamp < 30 && time >= stamp);
    touches.push(time);
    return mood(time);
  }

  function mood(time) {
    const recent = touches.filter(stamp => time - stamp < 30 && time >= stamp).length;
    return Math.min(1, Math.max(0, (recent - 1) / 6));
  }

  return { range, chance, pick, line, noteTouch, mood, random };
}

// ---- Idle routine ------------------------------------------------------------

const IDLE_ACTIONS = [
  { id: 'walk', weight: 2.6 },
  { id: 'lookAround', weight: 1.8 },
  { id: 'hum', weight: 1.6 },
  { id: 'wave', weight: 1.2 },
  { id: 'stretch', weight: 1.1 },
  { id: 'rest-standing', weight: 1.1 }
];

/**
 * Open-ended idle routine. Seeded, so it is stable for a given elapsed time within a
 * session (previews and both pages agree) but different every time the app starts.
 */
export function createRoutine({ seed = Date.now(), minAnchor = 0.2, maxAnchor = 0.64, startAnchor = 0.22 } = {}) {
  const random = mulberry32(seed);
  const variety = createVariety(random);
  const segments = [];
  let cursor = 0;
  let anchor = startAnchor;

  function nextDestination() {
    for (let attempt = 0; attempt < 8; attempt += 1) {
      const target = variety.range(minAnchor, maxAnchor);
      if (Math.abs(target - anchor) >= 0.12) return target;
    }
    return anchor < (minAnchor + maxAnchor) / 2 ? maxAnchor : minAnchor;
  }

  function generate() {
    cursor += variety.range(5, 15); // idle gap
    const name = variety.pick('idle', IDLE_ACTIONS);
    const variant = {
      speed: variety.range(0.85, 1.18),
      amplitude: variety.range(0.8, 1.2),
      side: variety.chance(0.5) ? '左' : '右',
      flip: variety.chance(0.5) ? 1 : -1,
      style: null
    };
    let duration;
    let fromAnchor = anchor;
    let toAnchor = anchor;
    switch (name) {
      case 'walk': {
        toAnchor = nextDestination();
        duration = Math.min(10, Math.max(4.5, 3 + Math.abs(toAnchor - fromAnchor) * 14));
        break;
      }
      case 'wave':
        variant.style = variety.pick('idleWave', ['big', 'small', 'tilt']);
        duration = variety.range(4.6, 6.2);
        break;
      case 'stretch':
        variant.style = variety.pick('idleStretch', ['plain', 'yawn', 'side']);
        duration = variety.range(5, 6.6);
        break;
      case 'rest-standing':
        duration = variety.range(8, 13);
        break;
      case 'lookAround':
        duration = variety.range(4, 6.5);
        break;
      case 'hum':
        duration = variety.range(6, 10);
        break;
      default:
        duration = 5;
    }
    segments.push({ name, start: cursor, end: cursor + duration, duration, fromAnchor, toAnchor, variant });
    cursor += duration;
    anchor = toAnchor;
  }

  function ensure(time) {
    let guard = 0;
    while (cursor <= time && guard < 5000) {
      generate();
      guard += 1;
    }
  }

  function find(time) {
    if (!Number.isFinite(time) || time < 0) return null;
    ensure(time);
    // Binary search for the segment containing `time`.
    let low = 0;
    let high = segments.length - 1;
    while (low <= high) {
      const middle = (low + high) >> 1;
      const segment = segments[middle];
      if (time < segment.start) high = middle - 1;
      else if (time >= segment.end) low = middle + 1;
      else return { segment, index: middle };
    }
    return { segment: null, index: high }; // in an idle gap after segments[high]
  }

  /** Behaviour at `time`: { name, progress, duration, fromAnchor, toAnchor, variant }. */
  function behaviorAt(time) {
    const found = find(time);
    const segment = found?.segment;
    if (!segment) return { name: 'idle', progress: 0, duration: 1, variant: null };
    return {
      name: segment.name,
      progress: Math.min(1, Math.max(0, (time - segment.start) / segment.duration)),
      duration: segment.duration,
      fromAnchor: segment.fromAnchor,
      toAnchor: segment.toAnchor,
      variant: segment.variant
    };
  }

  /** Where she rests at `time` (outside walks). */
  function restingAnchorAt(time) {
    const found = find(time);
    if (!found) return startAnchor;
    if (found.segment) return found.segment.fromAnchor;
    const previous = segments[found.index];
    return previous ? previous.toAnchor : startAnchor;
  }

  return { behaviorAt, restingAnchorAt };
}
