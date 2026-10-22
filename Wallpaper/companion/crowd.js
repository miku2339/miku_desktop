// The Shibuya scramble crossing: the signal cycle, people waiting and crossing in every
// direction, and the cars that go through between the walking phases.
//
// Everything here is in metres on the ground plane, seen from the camera: x to the right,
// z away from the camera (Miku stands on the near pavement, about 3 m in front of it).
// Pure logic, no drawing, so it can be tested; ambient.js draws what update() returns.

export const SIGNAL_PHASES = [
  // Cars go through; people gather at the kerbs.
  { name: 'cars', seconds: 30 },
  // Everyone else stops; the crossing clears.
  { name: 'clear', seconds: 3 },
  // Scramble: people walk in every direction, diagonals too.
  { name: 'walk', seconds: 20 },
  // Green man flashing: no new starters, the ones on the road hurry.
  { name: 'flash', seconds: 6 },
  { name: 'allRed', seconds: 3 }
];
export const SIGNAL_CYCLE = SIGNAL_PHASES.reduce((sum, phase) => sum + phase.seconds, 0);
const FLASH_SECONDS = SIGNAL_PHASES.find(phase => phase.name === 'flash').seconds;

/** Which phase the lights are in at `seconds` (any time base). */
export function signalAt(seconds) {
  let t = ((seconds % SIGNAL_CYCLE) + SIGNAL_CYCLE) % SIGNAL_CYCLE;
  for (const phase of SIGNAL_PHASES) {
    if (t < phase.seconds) {
      return {
        phase: phase.name,
        remaining: phase.seconds - t,
        walk: phase.name === 'walk' || phase.name === 'flash',
        flashing: phase.name === 'flash',
        cars: phase.name === 'cars'
      };
    }
    t -= phase.seconds;
  }
  return { phase: 'cars', remaining: 0, walk: false, flashing: false, cars: true };
}

/**
 * The crossing: kerb lines, how wide it is, where people wait and where cars drive.
 * Measured on shibuya-scramble-*.jpg (shibuya-scramble-layout.json) with the camera in
 * ambient.js (horizon 0.434, eye 1.25 m, focal 1.2): z = 1.5 / (imageY - 0.434). The near kerb
 * (y 0.77) is 4.5 m away, the far one (y 0.47) about 42 m, Miku's feet (y 0.915) 3.1 m.
 */
export const DEFAULT_SCRAMBLE = {
  nearKerb: 4.5,
  farKerb: 42,
  halfWidth: 22,
  // Waiting areas on the four corners, as [x0, x1, z0, z1]. The near pavement is the one
  // Miku stands on; the side corners are off the edges of the picture.
  pavements: {
    near: [-5, 5, 3.95, 4.4],
    far: [-24, 24, 42.6, 45],
    left: [-34, -27, 16, 34],
    right: [27, 34, 16, 34]
  },
  // At most this many wait on the near kerb, so the view across stays open.
  nearCap: 9,
  // Keep the near pavement clear right behind Miku.
  mikuGap: [-0.9, 0.9],
  // People just walking past along a pavement, whatever the lights say: z band, how far
  // out they start and finish (x), and the seconds between them.
  passers: [
    // Right behind Miku (she is at z 3.1, so they always pass behind her).
    { z: [3.45, 3.85], x: 7, gap: [2.5, 7] },
    { z: [42.8, 47], x: 30, gap: [0.5, 1.6] }
  ],
  // Lanes across the crossing (cars drive along x). Japan drives on the left: seen from
  // here, the nearer lanes go right → left, the farther ones left → right.
  lanes: [
    { z: 8.5, direction: -1 },
    { z: 11, direction: -1 },
    { z: 18, direction: 1 },
    { z: 23, direction: 1 }
  ],
  carSpeed: [8, 11],
  carGap: [1.6, 5]
};

function seededRandom(seed) {
  let value = seed >>> 0;
  return () => {
    value = (value * 1664525 + 1013904223) >>> 0;
    return value / 4294967296;
  };
}

const lerp = (a, b, t) => a + (b - a) * t;

/**
 * The people and cars of the crossing.
 * update(seconds, { rain }) advances them and returns { signal, people, cars } to draw.
 */
export function createScramble(layout = DEFAULT_SCRAMBLE, random = Math.random) {
  const people = [];
  const cars = [];
  let last = null;
  let nextArrival = 0;
  const nextPasser = (layout.passers ?? []).map(() => 0);
  const nextCar = layout.lanes.map(() => 0);
  let ids = 0;

  const pick = list => list[Math.floor(random() * list.length)];
  const range = ([min, max]) => min + random() * (max - min);

  function pointIn(name) {
    const [x0, x1, z0, z1] = layout.pavements[name];
    let x = lerp(x0, x1, random());
    if (name === 'near') {
      // Not right behind Miku, so she stays in the clear.
      const [g0, g1] = layout.mikuGap;
      if (x > g0 && x < g1) x = random() < 0.5 ? g0 - random() * 1.5 : g1 + random() * 1.5;
    }
    return { x, z: lerp(z0, z1, random()) };
  }

  // Where someone walks in from before they wait (off to the side of their corner), and
  // where they walk on to once across, along the pavement and out of sight.
  function besideCorner(name, spot, extra) {
    const [x0, x1] = layout.pavements[name];
    switch (name) {
      case 'near': return { x: spot.x < 0 ? x0 - 4 - extra : x1 + 4 + extra, z: spot.z };
      case 'far': return { x: spot.x < 0 ? x0 - 4 - extra : x1 + 4 + extra, z: spot.z + 0.6 + extra };
      case 'left': return { x: x0 - 2 - extra, z: spot.z };
      default: return { x: x1 + 2 + extra, z: spot.z };
    }
  }
  const entryFor = (name, spot) => besideCorner(name, spot, 0);
  const exitFor = (name, spot) => besideCorner(name, spot, 1);

  function makeLook() {
    return {
      height: range([1.5, 1.85]),
      build: range([0.85, 1.15]),
      coat: pick(['#2b2f3a', '#3a3f4b', '#1f2329', '#5b4a3e', '#6d7480', '#e8e4dc', '#8a2f3a', '#2f4b6b', '#c9b38f', '#4a5a3a', '#d8d2c8', '#ffffff']),
      legs: pick(['#1c1f26', '#2a2e38', '#3d3a36', '#24364f', '#5a5f68']),
      hair: pick(['#151515', '#2a1d14', '#3b2a1c', '#5a3d25', '#8a6a4a', '#1d1d24']),
      bag: random() < 0.45 ? pick(['#111', '#3a2a1e', '#7a5a3a', '#c8c0b0', '#20304a']) : null,
      phone: random() < 0.25,
      skirt: random() < 0.25,
      umbrella: pick(['clear', 'clear', 'clear', '#1f2a44', '#222', '#8a1f2b', '#2f5d50']),
      pace: range([1.15, 1.5]),
      sway: random() * Math.PI * 2,
      skin: pick(['#f1d3bc', '#e8c2a4', '#d9ab88', '#c4906c', '#f5dccb']),
      // Short hair, a bob, or long hair down the back.
      hairLength: pick([0, 0, 0, 1, 2]),
      // Where the coat / top ends, as a fraction of their height from the ground.
      hem: pick([0.5, 0.5, 0.46, 0.4, 0.32]),
      backpack: random() < 0.2,
      tights: pick(['#24242a', '#3a3036', '#e2c2a8'])
    };
  }

  function addPerson(origin, destination, { walkIn = true, start = 'wait' } = {}) {
    const spot = pointIn(origin);
    const goal = pointIn(destination);
    const entry = entryFor(origin, spot);
    const person = {
      id: ids += 1,
      origin,
      destination,
      look: makeLook(),
      x: walkIn ? entry.x : spot.x,
      z: walkIn ? entry.z : spot.z,
      // A route of points; 'state' says what they're doing on it.
      route: walkIn ? [spot] : [],
      state: walkIn ? 'arriving' : start,
      spot,
      goal,
      exit: exitFor(destination, goal),
      reaction: range([0.2, 2.6]),
      phase: random() * 10,
      heading: 0,
      speed: 0
    };
    people.push(person);
    return person;
  }

  const CROSSINGS = [
    ['near', 'far'], ['far', 'near'], ['near', 'far'], ['far', 'near'],
    ['left', 'right'], ['right', 'left'],
    ['near', 'left'], ['near', 'right'], ['far', 'left'], ['far', 'right'],
    ['left', 'near'], ['right', 'near'], ['left', 'far'], ['right', 'far']
  ];

  function stepToward(person, target, speed, delta) {
    const dx = target.x - person.x;
    const dz = target.z - person.z;
    const distance = Math.hypot(dx, dz);
    const step = speed * delta;
    person.speed = speed;
    if (distance > 1e-6) person.heading = Math.atan2(dx, dz);
    if (distance <= step) {
      person.x = target.x;
      person.z = target.z;
      return true;
    }
    person.x += dx / distance * step;
    person.z += dz / distance * step;
    return false;
  }

  function updatePeople(signal, delta, phaseTime) {
    for (let index = people.length - 1; index >= 0; index -= 1) {
      const person = people[index];
      const pace = person.look.pace;
      person.phase += delta * pace * 1.9;
      switch (person.state) {
        case 'arriving':
          // Walk along the pavement to a spot on the corner, then wait.
          if (stepToward(person, person.spot, pace, delta)) person.state = 'wait';
          break;
        case 'wait':
          person.speed = 0;
          // Facing the crossing while waiting.
          person.heading = Math.atan2(person.goal.x - person.x, person.goal.z - person.z);
          if (signal.phase === 'walk' && phaseTime >= person.reaction) person.state = 'cross';
          break;
        case 'cross': {
          // Hurry when the green man flashes or the lights have already changed, and fast
          // enough to be across before the cars go (a long diagonal takes a brisk walk).
          const hurry = signal.flashing ? 1.45 : signal.walk ? 1 : 1.8;
          const timeLeft = signal.phase === 'walk' ? signal.remaining + FLASH_SECONDS : signal.walk ? signal.remaining : 1;
          const left = Math.hypot(person.goal.x - person.x, person.goal.z - person.z);
          const speed = Math.min(3, Math.max(pace * hurry, left / Math.max(1, timeLeft - 0.5)));
          if (stepToward(person, person.goal, speed, delta)) person.state = 'leave';
          break;
        }
        case 'leave':
          if (stepToward(person, person.exit, pace, delta)) people.splice(index, 1);
          break;
        case 'pass':
          // Just walking past along a pavement.
          if (stepToward(person, person.exit, pace, delta)) people.splice(index, 1);
          break;
        default:
          people.splice(index, 1);
      }
    }
  }

  function updateCars(signal, delta, now) {
    layout.lanes.forEach((lane, index) => {
      // New cars only while the lights are with them (not in the last seconds).
      if (signal.cars && signal.remaining > 7 && now >= nextCar[index]) {
        const speed = range(layout.carSpeed);
        const startX = -lane.direction * (layout.halfWidth + 14);
        const behind = cars.filter(car => car.lane === index).at(-1);
        if (!behind || Math.abs(behind.x - startX) > 7) {
          cars.push({ id: ids += 1, lane: index, x: startX, z: lane.z, direction: lane.direction, speed, seed: random() * 1000, kindRoll: random(), colorRoll: random() });
        }
        nextCar[index] = now + range(layout.carGap) * (random() < 0.25 ? 2.5 : 1);
      }
    });
    for (let index = cars.length - 1; index >= 0; index -= 1) {
      const car = cars[index];
      // Keep a gap to the car ahead in the same lane.
      const ahead = cars.find(other => other !== car && other.lane === car.lane
        && (other.x - car.x) * car.direction > 0 && Math.abs(other.x - car.x) < 8);
      const target = ahead ? Math.min(car.speed, ahead.speed) : car.speed;
      car.x += car.direction * target * delta;
      if (Math.abs(car.x) > layout.halfWidth + 16) cars.splice(index, 1);
    }
  }

  function spawnArrivals(signal, now) {
    // People gather at the kerbs while the cars go; a few stragglers come during the walk.
    const waiting = people.filter(person => person.state === 'wait' || person.state === 'arriving').length;
    if (now < nextArrival) return;
    const busy = signal.cars || signal.phase === 'clear';
    const cap = 70;
    if (busy && waiting < cap) {
      let [origin, destination] = pick(CROSSINGS);
      const nearWaiting = people.filter(person => person.origin === 'near'
        && (person.state === 'wait' || person.state === 'arriving')).length;
      if (origin === 'near' && nearWaiting >= (layout.nearCap ?? Infinity)) [origin, destination] = [destination, origin];
      addPerson(origin, destination);
      nextArrival = now + range([0.25, 0.8]);
    } else {
      nextArrival = now + range([0.6, 1.4]);
    }
  }

  function addPasser(band) {
    const direction = random() < 0.5 ? -1 : 1;
    const z = range(band.z);
    const passer = {
      id: ids += 1,
      origin: 'pass',
      destination: 'pass',
      look: makeLook(),
      x: -direction * band.x,
      z,
      route: [],
      state: 'pass',
      spot: null,
      goal: null,
      exit: { x: direction * band.x, z },
      reaction: 0,
      phase: random() * 10,
      heading: direction > 0 ? Math.PI / 2 : -Math.PI / 2,
      speed: 0
    };
    people.push(passer);
    return passer;
  }

  function spawnPassers(now) {
    // People walking past along the pavements, whatever the lights say.
    (layout.passers ?? []).forEach((band, index) => {
      if (now < nextPasser[index]) return;
      addPasser(band);
      nextPasser[index] = now + range(band.gap);
    });
  }

  /** Fill the corners as if the scene had been running for a while (first frame). */
  function prime(signal) {
    for (let i = 0; i < 26; i += 1) {
      const [origin, destination] = pick(CROSSINGS);
      const person = addPerson(origin, destination, { walkIn: false });
      if (signal.walk) {
        // Already on their way across.
        const t = random();
        person.x = lerp(person.spot.x, person.goal.x, t);
        person.z = lerp(person.spot.z, person.goal.z, t);
        person.state = 'cross';
      }
    }
    for (const band of layout.passers ?? []) {
      // Already on their way past, spread along the pavement.
      const count = Math.round(band.x * 2 / (1.3 * (band.gap[0] + band.gap[1]) / 2));
      for (let i = 0; i < count; i += 1) {
        const passer = addPasser(band);
        passer.x = lerp(-band.x, band.x, random());
      }
    }
  }

  function step(seconds, delta, busy) {
    const signal = signalAt(seconds);
    const phaseIndex = SIGNAL_PHASES.findIndex(phase => phase.name === signal.phase);
    const phaseTime = SIGNAL_PHASES[phaseIndex].seconds - signal.remaining;
    if (random() < busy) spawnArrivals(signal, seconds);
    spawnPassers(seconds);
    updatePeople(signal, delta, phaseTime);
    updateCars(signal, delta, seconds);
    return signal;
  }

  function rebuild(seconds, busy) {
    people.length = 0;
    cars.length = 0;
    nextArrival = seconds;
    nextPasser.fill(seconds);
    nextCar.fill(seconds);
    prime(signalAt(seconds));
    return step(seconds, 0, busy);
  }

  function update(seconds, { busy = 1 } = {}) {
    if (last === null) {
      prime(signalAt(seconds));
      last = seconds;
    }
    // The lights run on the clock, so the people and cars must keep up with it even when
    // frames are slow. A long hidden-page pause skips whole signal phases, so rebuild at the
    // current phase instead of carrying stale crossers or cars into it.
    const gap = Math.max(0, seconds - last);
    if (gap > 20) {
      const signal = rebuild(seconds, busy);
      last = seconds;
      return { signal, people, cars };
    }
    let elapsed = gap;
    const stepLength = elapsed > 3 ? 0.25 : 0.1;
    let time = seconds - elapsed;
    let signal = signalAt(seconds);
    do {
      const delta = Math.min(stepLength, elapsed);
      time += delta;
      elapsed -= delta;
      signal = step(time, delta, busy);
    } while (elapsed > 1e-6);
    last = seconds;
    return { signal, people, cars };
  }

  return { update, people, cars, signalAt };
}

/** Same people every launch is fine; a seed makes tests repeatable. */
export function createSeededScramble(seed, layout = DEFAULT_SCRAMBLE) {
  return createScramble(layout, seededRandom(seed));
}
