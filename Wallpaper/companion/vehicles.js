// Street traffic, drawn as small cel-shaded 3D vehicles.
//
// World units are fractions of the picture height at the reference row of the road
// (`refY`, where z = 1). The camera sits at the horizon height looking down the road,
// so a point (X, Y, Z) lands on screen at
//   x = vanishX + X · f / Z,   y = vanishY + (cameraHeight − Y) · f / Z.
//
// Two kinds of road:
// - 'cross3d': a main road crossing the picture left↔right, seen from a side street
//   (the GiGO Akihabara corner). Japan drives on the left, so the near lanes run
//   right→left and the far lanes left→right; vehicles show their sides.
// - 'street3d': a road running away from the camera, where oncoming cars turn off at
//   the junction instead of driving into Miku.
// Either way, traffic always stays behind where Miku stands.

// Side silhouettes, rear → over the roof → front: [z (fraction of length), y (car widths), edge role].
// The role names the face that runs from this point to the next one.
const PROFILES = {
  sedan: {
    outline: [[-0.5, 0.15, 'rear'], [-0.5, 0.42, 'trunk'], [-0.45, 0.49, 'trunk'], [-0.3, 0.51, 'rearglass'], [-0.16, 0.8, 'roof'], [0.07, 0.81, 'windscreen'], [0.22, 0.53, 'hood'], [0.45, 0.47, 'nose'], [0.5, 0.4, 'front'], [0.5, 0.15, 'under']],
    window: [[-0.27, 0.54], [-0.15, 0.76], [0.06, 0.77], [0.19, 0.54]],
    belt: 0.52,
    doors: [-0.2, 0.06]
  },
  kei: {
    outline: [[-0.5, 0.15, 'rear'], [-0.5, 0.93, 'roof'], [-0.45, 1.02, 'roof'], [0.12, 1.03, 'windscreen'], [0.36, 0.56, 'hood'], [0.48, 0.51, 'nose'], [0.5, 0.44, 'front'], [0.5, 0.15, 'under']],
    window: [[-0.46, 0.6], [-0.42, 0.97], [0.11, 0.98], [0.32, 0.6]],
    belt: 0.58,
    doors: [-0.12, 0.14],
    tallLamps: true
  },
  minivan: {
    outline: [[-0.5, 0.15, 'rear'], [-0.5, 0.86, 'roof'], [-0.45, 0.95, 'roof'], [0.12, 0.97, 'windscreen'], [0.33, 0.56, 'hood'], [0.47, 0.51, 'nose'], [0.5, 0.43, 'front'], [0.5, 0.15, 'under']],
    window: [[-0.46, 0.6], [-0.42, 0.9], [0.11, 0.91], [0.29, 0.6]],
    belt: 0.58,
    doors: [-0.18, 0.1],
    tallLamps: true
  },
  // Toyota JPN Taxi: tall, upright wagon with a short sloping bonnet and a big sliding rear door.
  jpntaxi: {
    outline: [[-0.5, 0.15, 'rear'], [-0.5, 0.9, 'roof'], [-0.46, 1.01, 'roof'], [0.06, 1.03, 'windscreen'], [0.29, 0.6, 'hood'], [0.47, 0.53, 'nose'], [0.5, 0.45, 'front'], [0.5, 0.15, 'under']],
    window: [[-0.45, 0.63], [-0.43, 0.96], [0.05, 0.97], [0.26, 0.63]],
    belt: 0.61,
    doors: [-0.06, 0.13],
    tallLamps: true,
    sign: { length: 0.07, height: 0.07, width: 0.22, color: '#f6e7a6' },
    vacancy: true
  },
  // The old Toyota Crown Comfort: a square-cut three-box saloon with a big company roof lamp.
  crowntaxi: {
    outline: [[-0.5, 0.15, 'rear'], [-0.5, 0.5, 'trunk'], [-0.47, 0.53, 'trunk'], [-0.31, 0.54, 'rearglass'], [-0.2, 0.84, 'roof'], [0.09, 0.85, 'windscreen'], [0.21, 0.56, 'hood'], [0.48, 0.53, 'nose'], [0.5, 0.47, 'front'], [0.5, 0.15, 'under']],
    window: [[-0.29, 0.58], [-0.19, 0.8], [0.08, 0.81], [0.18, 0.58]],
    belt: 0.56,
    doors: [-0.19, 0.06],
    sign: { length: 0.06, height: 0.11, width: 0.32, color: '#f6e7a6' },
    vacancy: true
  }
};
// The GO-liveried taxi uses the JPN Taxi body.
PROFILES.gotaxi = { ...PROFILES.jpntaxi, sign: { ...PROFILES.jpntaxi.sign, color: '#f4f5f7' } };

// Two-tone paint and stripes (no company names or logos).
const LIVERIES = {
  crowntaxi: [
    { body: '#17191e' },
    { body: '#f2c230', lower: '#202226', stripe: '#d92b2b' },
    { body: '#ebe8dc', lower: '#2e6b4f' },
    { body: '#e8dcc0', lower: '#7a1f2b' },
    { body: '#f4f5f7', lower: '#2b5aa8' }
  ],
  // Provisional GO colours: black with a white belt line.
  gotaxi: [{ body: '#121316', stripe: '#f4f5f7' }]
};

export const VEHICLE_TYPES = {
  sedan: { weight: 3, width: 1, length: 2.55, body: 0.36, clearance: 0.12, cabin: { height: 0.32, base: 0.88, top: 0.72, bottom: [-0.33, 0.18], roof: [-0.2, 0.04] }, plate: 'white' },
  kei: { weight: 2.6, width: 0.84, length: 2.2, body: 0.42, clearance: 0.12, cabin: { height: 0.52, base: 0.94, top: 0.86, bottom: [-0.48, 0.24], roof: [-0.46, 0.1] }, plate: 'yellow' },
  minivan: { weight: 1.6, width: 1, length: 2.75, body: 0.44, clearance: 0.13, cabin: { height: 0.46, base: 0.92, top: 0.84, bottom: [-0.48, 0.22], roof: [-0.46, 0.06] }, plate: 'white' },
  jpntaxi: { weight: 1.2, width: 0.99, length: 2.6, plate: 'green' },
  crowntaxi: { weight: 0.75, width: 1, length: 2.72, plate: 'green' },
  gotaxi: { weight: 0.6, width: 0.99, length: 2.6, plate: 'green' },
  truck: { weight: 0.6, width: 1.1, length: 3.3, plate: 'green', truck: true },
  bus: { weight: 0.3, width: 1.22, length: 4.6, plate: 'green', bus: true }
};

const COLORS = {
  sedan: ['#f4f5f7', '#1d1f24', '#c4c9cf', '#2b3a67', '#b3202a', '#30343b', '#5b7c99', '#e7e2d4'],
  kei: ['#f4f5f7', '#e8d9b5', '#8fc3c0', '#e9a6b0', '#c4c9cf', '#3b3f46', '#f2c230', '#9cb86a'],
  minivan: ['#f4f5f7', '#1d1f24', '#c4c9cf', '#30343b', '#6d7a86', '#e7e2d4'],
  jpntaxi: ['#1b2440'],
  truck: ['#eef0f2'],
  bus: ['#f1f2ee']
};
const PLATES = { white: '#f2f2ec', yellow: '#f1cf34', green: '#1f6b3a' };

const clamp = (value, min, max) => Math.min(max, Math.max(min, value));

// ---- roads and paths --------------------------------------------------------

/**
 * Builds the two traffic paths from a road description.
 * road: { focal, aspect, vanish:[x,y], lanes:[{x,direction}], junction (z), far (z), turnRadius, crossOffset, hideX }
 */
export function buildPaths(road) {
  if (road.kind === 'cross3d') return buildCrossPaths(road);
  const f = road.focal;
  const laneX = direction => (road.lanes.find(lane => lane.direction === direction).x - road.vanish[0]) * road.aspect;
  const junction = road.junction * f;
  const crossLane = junction + road.crossOffset;
  const far = road.far * f;
  const R = road.turnRadius;
  const towardX = laneX('toward');
  const awayX = laneX('away');
  const outside = road.hideX + 0.6;
  return {
    // Oncoming: down the right lane, left turn into the side street on the right.
    toward: makePath([
      { type: 'line', from: [towardX, far], to: [towardX, crossLane + R] },
      { type: 'arc', center: [towardX + R, crossLane + R], radius: R, start: Math.PI, sweep: Math.PI / 2 },
      { type: 'line', from: [towardX + R, crossLane], to: [outside, crossLane] }
    ]),
    // Heading away: out of the side street on the left, left turn, off down the left lane.
    away: makePath([
      { type: 'line', from: [-outside, crossLane], to: [awayX - R, crossLane] },
      { type: 'arc', center: [awayX - R, crossLane + R], radius: R, start: -Math.PI / 2, sweep: Math.PI / 2 },
      { type: 'line', from: [awayX, crossLane + R], to: [awayX, far] }
    ])
  };
}

/** Depth (z) of a ground row y on screen: row refY is z = 1. */
export function rowDepth(road, y) {
  return (road.refY - road.vanish[1]) / Math.max(1e-4, y - road.vanish[1]);
}

function buildCrossPaths(road) {
  const paths = {};
  road.lanes.forEach((lane, index) => {
    const z = rowDepth(road, lane.y);
    const Z = z * road.focal;
    // From just off one side of the picture to just off the other (plus a car length).
    const half = (0.5 * road.aspect) * z + 0.5;
    const sign = lane.direction === 'right' ? 1 : -1;
    paths[`lane${index}`] = makePath([{ type: 'line', from: [-sign * half, Z], to: [sign * half, Z] }]);
  });
  return paths;
}

function makePath(segments) {
  let total = 0;
  const parts = segments.map(segment => {
    const length = segment.type === 'line'
      ? Math.hypot(segment.to[0] - segment.from[0], segment.to[1] - segment.from[1])
      : Math.abs(segment.sweep) * segment.radius;
    const part = { ...segment, start: segment.start, offset: total, length };
    total += length;
    return part;
  });
  return { parts, length: total };
}

/** Position (x, z on the ground) and heading (radians; 0 = away from camera, π/2 = to the right) at distance d. */
export function pointOnPath(path, d) {
  const distance = clamp(d, 0, path.length);
  const part = path.parts.find(candidate => distance <= candidate.offset + candidate.length) ?? path.parts.at(-1);
  const t = part.length > 0 ? (distance - part.offset) / part.length : 0;
  if (part.type === 'line') {
    const dx = part.to[0] - part.from[0];
    const dz = part.to[1] - part.from[1];
    return { x: part.from[0] + dx * t, z: part.from[1] + dz * t, heading: Math.atan2(dx, dz), turning: false };
  }
  const angle = part.start + part.sweep * t;
  const direction = Math.sign(part.sweep);
  const tx = -Math.sin(angle) * direction;
  const tz = Math.cos(angle) * direction;
  return {
    x: part.center[0] + part.radius * Math.cos(angle),
    z: part.center[1] + part.radius * Math.sin(angle),
    heading: Math.atan2(tx, tz),
    turning: true,
    sweep: part.sweep
  };
}

function distanceToNextArc(path, d) {
  for (const part of path.parts) {
    if (part.type === 'arc' && part.offset + part.length > d) return Math.max(0, part.offset - d);
  }
  return Infinity;
}

function distanceSinceLastArc(path, d) {
  let since = Infinity;
  for (const part of path.parts) {
    if (part.type === 'arc' && part.offset + part.length <= d) since = d - (part.offset + part.length);
  }
  return since;
}

const CRUISE = 0.85; // world units per second (~45 km/h)
const TURN_SPEED = 0.26;
const BRAKING = 0.32;

/** Speed a vehicle wants at distance d: slow for the corner, then pull away again. */
export function desiredSpeed(path, d, cruise = CRUISE) {
  const before = distanceToNextArc(path, d);
  const after = distanceSinceLastArc(path, d);
  const inTurn = before === 0 && pointOnPath(path, d).turning;
  if (inTurn) return TURN_SPEED;
  const slowing = Math.sqrt(TURN_SPEED ** 2 + 2 * BRAKING * before);
  const speeding = Math.sqrt(TURN_SPEED ** 2 + 2 * BRAKING * 1.4 * after);
  return Math.min(cruise, slowing, speeding);
}

function pickType(random) {
  const entries = Object.entries(VEHICLE_TYPES);
  const total = entries.reduce((sum, [, type]) => sum + type.weight, 0);
  let roll = random() * total;
  for (const [name, type] of entries) {
    roll -= type.weight;
    if (roll <= 0) return name;
  }
  return 'sedan';
}

/** One vehicle (type, size, paint) for scenes that move their own cars, like the Shibuya crossing. */
export function makeVehicle(random = Math.random) {
  const type = pickType(random);
  const spec = VEHICLE_TYPES[type];
  const liveries = LIVERIES[type];
  const colors = COLORS[type] ?? ['#f4f5f7'];
  const paint = liveries
    ? (() => {
      const livery = liveries[Math.floor(random() * liveries.length)];
      return { color: livery.body, livery };
    })()
    : { color: colors[Math.floor(random() * colors.length)] };
  return { type, typeWidth: spec.width, ...paint, seed: random() * 1000 };
}

/** Traffic on one road: spawning, following distance and cornering speed. */
export function createTraffic(road, random = Math.random) {
  const paths = buildPaths(road);
  const kinds = Object.keys(paths);
  const cars = [];
  const timers = Object.fromEntries(kinds.map(kind => [kind, null]));
  const [quickGap, slowGap] = road.spawnGaps ?? [[1800, 3600], [5000, 14000]];
  let last = null;

  function spawn(kind, now) {
    const path = paths[kind];
    const behind = cars.filter(car => car.kind === kind).at(-1);
    const type = pickType(random);
    const spec = VEHICLE_TYPES[type];
    const length = road.carWidth * spec.width * spec.length;
    if (behind && behind.d - VEHICLE_TYPES[behind.type].length * road.carWidth * VEHICLE_TYPES[behind.type].width < length * 0.6 + 0.12) return false;
    const colors = COLORS[type] ?? ['#f4f5f7'];
    cars.push({
      kind,
      path,
      type,
      typeWidth: spec.width,
      ...(() => {
        const liveries = LIVERIES[type];
        if (!liveries) return { color: colors[Math.floor(random() * colors.length)] };
        const livery = liveries[Math.floor(random() * liveries.length)];
        return { color: livery.body, livery };
      })(),
      d: 0,
      speed: desiredSpeed(path, 0),
      cruise: CRUISE * (type === 'bus' || type === 'truck' ? 0.8 : 0.9 + random() * 0.25),
      seed: random() * 1000,
      born: now
    });
    return true;
  }

  function update(now) {
    const delta = last === null ? 0 : clamp((now - last) / 1000, 0, 0.25);
    last = now;
    for (const kind of kinds) {
      if (timers[kind] === null) timers[kind] = now + 800 + random() * 6000;
      if (now >= timers[kind]) {
        const placed = spawn(kind, now);
        // Sometimes a little convoy, sometimes a quiet road.
        const [min, max] = random() < 0.3 ? quickGap : slowGap;
        timers[kind] = now + (placed ? min + random() * (max - min) : 600);
      }
    }
    for (const kind of kinds) {
      const lane = cars.filter(car => car.kind === kind);
      lane.forEach((car, index) => {
        let target = desiredSpeed(car.path, car.d, car.cruise);
        const ahead = lane[index - 1];
        if (ahead) {
          // Keep a safe gap to the vehicle in front (ahead has the larger d).
          const aheadLength = VEHICLE_TYPES[ahead.type].length * road.carWidth * VEHICLE_TYPES[ahead.type].width;
          const gap = ahead.d - car.d - aheadLength / 2 - VEHICLE_TYPES[car.type].length * road.carWidth * VEHICLE_TYPES[car.type].width / 2;
          target = Math.min(target, Math.max(0, (gap - 0.06) * 2.2), ahead.speed + Math.max(0, gap - 0.2));
        }
        // Smooth acceleration and braking.
        const rate = target > car.speed ? 0.35 : 1.2;
        car.speed += clamp(target - car.speed, -rate * delta, rate * delta);
        car.d += Math.max(0, car.speed) * delta;
      });
    }
    for (let index = cars.length - 1; index >= 0; index -= 1) {
      if (cars[index].d >= cars[index].path.length) cars.splice(index, 1);
    }
    return cars;
  }

  return { update, cars, paths };
}

// ---- drawing ---------------------------------------------------------------------

function hexToRgb(hex) {
  const value = parseInt(hex.slice(1), 16);
  return [(value >> 16) & 255, (value >> 8) & 255, value & 255];
}

function makePainter(look) {
  const hazeRgb = hexToRgb(look.hazeColor);
  return (hex, factor = 1, alpha = 1) => {
    const rgb = typeof hex === 'string' ? hexToRgb(hex) : hex;
    const out = rgb.map((channel, index) => {
      const lit = channel * look.light * factor * look.tint[index];
      return Math.round(clamp(lit + (hazeRgb[index] * look.light * look.tint[index] - lit) * look.haze, 0, 255));
    });
    return alpha >= 1 ? `rgb(${out[0]} ${out[1]} ${out[2]})` : `rgb(${out[0]} ${out[1]} ${out[2]} / ${alpha})`;
  };
}

const LIGHT = (() => {
  const v = [-0.45, 0.8, -0.4];
  const length = Math.hypot(...v);
  return v.map(c => c / length);
})();

/**
 * A box (or a frustum: different top and bottom extents) in the vehicle's own frame:
 * x across, y up, z forwards. Returns its 6 faces as corner lists with outward normals.
 */
function prism(bottom, top) {
  // bottom/top: { x0, x1, z0, z1, y }
  const b = [[bottom.x0, bottom.y, bottom.z0], [bottom.x1, bottom.y, bottom.z0], [bottom.x1, bottom.y, bottom.z1], [bottom.x0, bottom.y, bottom.z1]];
  const t = [[top.x0, top.y, top.z0], [top.x1, top.y, top.z0], [top.x1, top.y, top.z1], [top.x0, top.y, top.z1]];
  return [
    { name: 'top', corners: [t[0], t[1], t[2], t[3]] },
    { name: 'front', corners: [b[3], b[2], t[2], t[3]] },
    { name: 'back', corners: [b[1], b[0], t[0], t[1]] },
    { name: 'right', corners: [b[2], b[1], t[1], t[2]] },
    { name: 'left', corners: [b[0], b[3], t[3], t[0]] }
  ];
}

const box = (x0, x1, y0, y1, z0, z1) => prism({ x0, x1, z0, z1, y: y0 }, { x0, x1, z0, z1, y: y1 });

/** The vehicle's parts as lists of faces, each with a role (paint, glass, tyre…). */
function vehicleParts(spec, w) {
  const half = w / 2;
  const L = spec.length * w;
  const parts = [];
  const tyreR = 0.17 * w;
  const wheelbase = L * 0.33;
  // Tyres first: the body then covers their tops, leaving them peeking out below.
  for (const side of [-1, 1]) {
    for (const end of [-1, 1]) {
      const x0 = side < 0 ? -half + 0.01 * w : half - 0.17 * w;
      parts.push({ role: 'tyre', faces: box(x0, x0 + 0.16 * w, 0, tyreR * 2, end * wheelbase - tyreR, end * wheelbase + tyreR) });
    }
  }
  if (spec.bus) {
    const top = 1.25 * w;
    parts.push({ role: 'paint', faces: box(-half, half, 0.12 * w, top, -L / 2, L / 2), details: 'bus', top });
    return { parts, length: L };
  }
  if (spec.truck) {
    parts.push({ role: 'cargo', faces: box(-half, half, 0.2 * w, 1.15 * w, -L / 2, L * 0.18), details: 'cargo' });
    parts.push({ role: 'cab', faces: box(-half * 0.96, half * 0.96, 0.14 * w, 0.95 * w, L * 0.2, L / 2), details: 'cab' });
    return { parts, length: L };
  }
  const bodyBottom = spec.clearance * w;
  const bodyTop = bodyBottom + spec.body * w;
  parts.push({ role: 'paint', faces: box(-half, half, bodyBottom, bodyTop, -L / 2, L / 2), details: 'body', bodyBottom, bodyTop });
  const c = spec.cabin;
  parts.push({
    role: 'cabin',
    faces: prism(
      { x0: -half * c.base, x1: half * c.base, z0: c.bottom[0] * L, z1: c.bottom[1] * L, y: bodyTop },
      { x0: -half * c.top, x1: half * c.top, z0: c.roof[0] * L, z1: c.roof[1] * L, y: bodyTop + c.height * w }
    ),
    details: 'cabin'
  });
  if (spec.sign) {
    const roof = bodyTop + c.height * w;
    const mid = (c.roof[0] + c.roof[1]) / 2 * L;
    parts.push({ role: 'sign', faces: box(-0.13 * w, 0.13 * w, roof, roof + 0.08 * w, mid - 0.05 * w, mid + 0.05 * w) });
  }
  return { parts, length: L };
}

const partCache = new Map();
function partsFor(type, w) {
  const key = `${type}:${w.toFixed(5)}`;
  if (!partCache.has(key)) {
    if (partCache.size > 64) partCache.clear();
    partCache.set(key, vehicleParts(VEHICLE_TYPES[type], w));
  }
  return partCache.get(key);
}

function lerp3(a, b, t) {
  return [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t];
}

/** Point on a face quad at (u across, v up), corners ordered bottom-left, bottom-right, top-right, top-left. */
function onFace(corners, u, v) {
  return lerp3(lerp3(corners[0], corners[1], u), lerp3(corners[3], corners[2], u), v);
}

/** Shared projection, lighting and painting helpers for one vehicle this frame. */
function makeFrame(vehicle, pose, cam, look, w, mirrored = false) {
  const paint = makePainter(look);
  const cos = Math.cos(pose.heading);
  const sin = Math.sin(pose.heading);
  const bob = Math.sin(look.now / 1000 * Math.PI * 2 * 1.6 + vehicle.seed) * w * 0.006;
  const roll = pose.roll ?? 0;
  const toWorld = ([px, py, pz], body = true) => {
    const lean = body ? roll * (py / w) : 0;
    const lx = px + lean * w * 0.5;
    const ly = py + (body ? bob : 0);
    return [pose.x + lx * cos + pz * sin, ly, pose.z - lx * sin + pz * cos];
  };
  const rotate = ([nx, ny, nz]) => [nx * cos + nz * sin, ny, -nx * sin + nz * cos];
  const facing = (normalLocal, pointWorld) => {
    const n = rotate(normalLocal);
    return n[0] * -pointWorld[0] + n[1] * (cam.height - pointWorld[1]) + n[2] * -pointWorld[2] > 0;
  };
  const shadeOf = normalLocal => {
    const n = rotate(normalLocal);
    return 0.74 + 0.3 * Math.max(0, n[0] * LIGHT[0] + n[1] * LIGHT[1] + n[2] * LIGHT[2]) + 0.06 * n[1];
  };
  const pixels = w * cam.scaleAt(pose.z);
  const project = ([x, y, z]) => cam.project(x, mirrored ? -y : y, z);
  return { paint, toWorld, facing, shadeOf, pixels, project };
}

function fillPath(ctx, points) {
  ctx.beginPath();
  points.forEach(([x, y], index) => (index ? ctx.lineTo(x, y) : ctx.moveTo(x, y)));
  ctx.closePath();
}

/** A round wheel on the outside of the side at local x, centred at (z, r). */
function drawWheel(ctx, frame, x, z, r, look, near) {
  const { paint, toWorld, project } = frame;
  const ring = (radius, xOffset = 0) => Array.from({ length: 18 }, (_, index) => {
    const angle = index / 18 * Math.PI * 2;
    return project(toWorld([x + xOffset, r + Math.sin(angle) * radius, z + Math.cos(angle) * radius], false));
  });
  fillPath(ctx, ring(r));
  ctx.fillStyle = paint('#15171b');
  ctx.fill();
  if (!near) return;
  fillPath(ctx, ring(r * 0.58, Math.sign(x) * 0.001));
  ctx.fillStyle = paint('#9aa3ab', 1.05);
  ctx.fill();
  fillPath(ctx, ring(r * 0.2, Math.sign(x) * 0.002));
  ctx.fillStyle = paint('#5a6168');
  ctx.fill();
}

/** Cars: a side silhouette extruded across the car's width, with windows, doors and lamps. */
function drawProfileCar(ctx, vehicle, pose, cam, look, w, mirrored = false) {
  const spec = VEHICLE_TYPES[vehicle.type];
  const profile = PROFILES[vehicle.type];
  const frame = makeFrame(vehicle, pose, cam, look, w, mirrored);
  const { paint, toWorld, facing, shadeOf, pixels, project } = frame;
  const L = spec.length * w;
  const half = w / 2;
  const night = look.night;
  const outlineColor = `rgb(22 26 36 / ${0.5 * (1 - look.haze)})`;
  const outlineWidth = Math.max(0.4, pixels * 0.012);
  const points = profile.outline.map(([z, y, role]) => ({ z: z * L, y: y * w, role }));
  const wheelR = 0.18 * w;
  const wheelZ = [-0.31 * L, 0.31 * L];

  // Which side faces us?
  const nearSign = facing([1, 0, 0], toWorld([half, 0.5 * w, 0])) ? 1 : -1;
  const nearX = nearSign * half;
  const farX = -nearX;

  if (!mirrored) {
    // Contact shadow.
    ctx.save();
    ctx.filter = `blur(${Math.max(0.6, pixels * 0.05).toFixed(2)}px)`;
    fillPath(ctx, [[-0.56 * w, -L * 0.54], [0.56 * w, -L * 0.54], [0.56 * w, L * 0.54], [-0.56 * w, L * 0.54]]
      .map(([x, z]) => project(toWorld([x, 0, z], false))));
    ctx.fillStyle = `rgb(8 10 18 / ${0.42 * (1 - night * 0.35)})`;
    ctx.fill();
    ctx.restore();
  }

  // Far wheels peek out under the body.
  for (const z of wheelZ) drawWheel(ctx, frame, farX * 0.92, z, wheelR, look, false);

  // Faces between the two sides: roof, glass, bonnet, front and rear.
  const strips = [];
  for (let index = 0; index < points.length; index += 1) {
    const p = points[index];
    const q = points[(index + 1) % points.length];
    const tz = q.z - p.z;
    const ty = q.y - p.y;
    const length = Math.hypot(tz, ty) || 1;
    const normal = [0, tz / length, -ty / length];
    const mid = toWorld([0, (p.y + q.y) / 2, (p.z + q.z) / 2]);
    if (p.role === 'under' || !facing(normal, mid)) continue;
    const corners = [toWorld([-half, p.y, p.z]), toWorld([half, p.y, p.z]), toWorld([half, q.y, q.z]), toWorld([-half, q.y, q.z])];
    strips.push({ role: p.role, corners, normal, distance: Math.hypot(mid[0], mid[2]) });
  }
  strips.sort((a, b) => b.distance - a.distance);
  for (const strip of strips) {
    const glass = strip.role === 'windscreen' || strip.role === 'rearglass';
    fillPath(ctx, strip.corners.map(project));
    ctx.fillStyle = glass ? paint(night > 0.5 ? '#232b37' : '#6f88a0', 0.9 + 0.2 * Math.max(0, strip.normal[1])) : paint(vehicle.color, shadeOf(strip.normal));
    ctx.fill();
    ctx.strokeStyle = outlineColor;
    ctx.lineWidth = outlineWidth;
    ctx.stroke();
    if (strip.role === 'front' || strip.role === 'rear') {
      const front = strip.role === 'front';
      // Place lamps and plate by real height, whichever way round this face runs.
      const [ya, yb] = [strip.corners[0][1], strip.corners[3][1]];
      const vAt = y => (y - ya) / (yb - ya || 1);
      const color = front ? (night > 0.2 ? 'rgb(255 250 228)' : paint('#e2e9ee', 1.1)) : (night > 0.2 ? 'rgb(255 55 60)' : paint('#b3141e', 1.15));
      const lampY = front ? [0.33 * w, 0.41 * w] : profile.tallLamps ? [0.34 * w, 0.6 * w] : [0.36 * w, 0.45 * w];
      const lampU = front || !profile.tallLamps ? [[0.04, 0.22], [0.78, 0.96]] : [[0.03, 0.12], [0.88, 0.97]];
      for (const [u0, u1] of lampU) {
        const v = [vAt(lampY[0]), vAt(lampY[1])];
        const quad = [onFace(strip.corners, u0, v[0]), onFace(strip.corners, u1, v[0]), onFace(strip.corners, u1, v[1]), onFace(strip.corners, u0, v[1])].map(project);
        fillPath(ctx, quad);
        ctx.fillStyle = color;
        ctx.fill();
        if (night > 0.2) {
          const [cx, cy] = project(onFace(strip.corners, (u0 + u1) / 2, (v[0] + v[1]) / 2));
          const radius = Math.max(3, pixels * 0.3);
          const [r, g, b] = color.match(/\d+/g).map(Number);
          const glow = ctx.createRadialGradient(cx, cy, 0, cx, cy, radius);
          glow.addColorStop(0, `rgb(${r} ${g} ${b} / ${0.55 * night})`);
          glow.addColorStop(1, `rgb(${r} ${g} ${b} / 0)`);
          ctx.fillStyle = glow;
          ctx.fillRect(cx - radius, cy - radius, radius * 2, radius * 2);
        }
      }
      const plateV = [vAt(0.21 * w), vAt(0.3 * w)];
      const plate = [onFace(strip.corners, 0.4, plateV[0]), onFace(strip.corners, 0.6, plateV[0]), onFace(strip.corners, 0.6, plateV[1]), onFace(strip.corners, 0.4, plateV[1])].map(project);
      fillPath(ctx, plate);
      ctx.fillStyle = paint(PLATES[spec.plate] ?? PLATES.white, 1 + night * 0.4);
      ctx.fill();
    }
  }

  // The near side: body colour, lighter towards the shoulder.
  const side = points.map(point => project(toWorld([nearX, point.y, point.z])));
  const top = project(toWorld([nearX, profile.belt * w + 0.1 * w, 0]))[1];
  const bottom = project(toWorld([nearX, 0.15 * w, 0]))[1];
  const sideShade = shadeOf([nearSign, 0, 0]);
  const gradient = ctx.createLinearGradient(0, top, 0, bottom);
  gradient.addColorStop(0, paint(vehicle.color, sideShade * 1.12));
  gradient.addColorStop(0.45, paint(vehicle.color, sideShade));
  gradient.addColorStop(1, paint(vehicle.color, sideShade * 0.72));
  fillPath(ctx, side);
  ctx.fillStyle = gradient;
  ctx.fill();
  ctx.strokeStyle = outlineColor;
  ctx.lineWidth = outlineWidth;
  ctx.stroke();

  const onSide = (z, y) => project(toWorld([nearX * 1.001, y, z]));
  const livery = vehicle.livery;
  if (livery?.lower || livery?.stripe) {
    ctx.save();
    fillPath(ctx, side);
    ctx.clip();
    const band = (y0, y1, color, factor = 1) => {
      fillPath(ctx, [onSide(-0.6 * L, y0), onSide(0.6 * L, y0), onSide(0.6 * L, y1), onSide(-0.6 * L, y1)]);
      ctx.fillStyle = paint(color, sideShade * factor);
      ctx.fill();
    };
    if (livery.lower) band(0.1 * w, (profile.belt - 0.17) * w, livery.lower, 0.9);
    if (livery.stripe) band((profile.belt - 0.19) * w, (profile.belt - 0.15) * w, livery.stripe, 1.05);
    ctx.restore();
  }
  // Wheel arches.
  for (const z of wheelZ) {
    const arch = Array.from({ length: 13 }, (_, index) => {
      const angle = Math.PI * index / 12;
      return onSide(z + Math.cos(angle) * wheelR * 1.18, wheelR + Math.sin(angle) * wheelR * 1.18);
    });
    fillPath(ctx, arch);
    ctx.fillStyle = paint('#14161a');
    ctx.fill();
  }
  // Side windows, split by the pillar.
  const windowPoints = profile.window.map(([z, y]) => onSide(z * L, y * w));
  fillPath(ctx, windowPoints);
  const glassTop = Math.min(...windowPoints.map(point => point[1]));
  const glassBottom = Math.max(...windowPoints.map(point => point[1]));
  const glass = ctx.createLinearGradient(0, glassTop, 0, glassBottom);
  glass.addColorStop(0, paint(night > 0.5 ? '#2c3646' : '#9bb3c7'));
  glass.addColorStop(1, paint(night > 0.5 ? '#1a2029' : '#4a5a6b'));
  ctx.fillStyle = glass;
  ctx.fill();
  const pillarZ = profile.doors[1] * L;
  const pillarTop = Math.max(...profile.window.map(([, y]) => y)) * w;
  ctx.strokeStyle = paint(vehicle.color, 0.75);
  ctx.lineWidth = Math.max(0.8, pixels * 0.04);
  ctx.beginPath();
  ctx.moveTo(...onSide(pillarZ, profile.belt * w));
  ctx.lineTo(...onSide(pillarZ - 0.02 * L, pillarTop));
  ctx.stroke();
  // Door seams and handles.
  ctx.strokeStyle = `rgb(20 24 32 / ${0.35 * (1 - look.haze)})`;
  ctx.lineWidth = Math.max(0.4, pixels * 0.008);
  for (const z of profile.doors) {
    ctx.beginPath();
    ctx.moveTo(...onSide(z * L, profile.belt * w));
    ctx.lineTo(...onSide(z * L, 0.2 * w));
    ctx.stroke();
    const handle = [onSide(z * L - 0.09 * w, profile.belt * w - 0.07 * w), onSide(z * L - 0.02 * w, profile.belt * w - 0.07 * w)];
    ctx.beginPath();
    ctx.moveTo(...handle[0]);
    ctx.lineTo(...handle[1]);
    ctx.stroke();
  }
  // Shoulder highlight catching the sky.
  ctx.strokeStyle = `rgb(255 255 255 / ${0.35 * (1 - night * 0.7) * (1 - look.haze)})`;
  ctx.lineWidth = Math.max(0.6, pixels * 0.012);
  ctx.beginPath();
  ctx.moveTo(...onSide(-0.46 * L, profile.belt * w - 0.03 * w));
  ctx.lineTo(...onSide(0.44 * L, profile.belt * w - 0.03 * w));
  ctx.stroke();
  // Little lamps at the corners of the side.
  const frontZ = 0.49 * L;
  const lampY = (profile.outline.find(point => point[2] === 'front')?.[1] ?? 0.42) * w;
  fillPath(ctx, [onSide(frontZ - 0.06 * w, lampY - 0.07 * w), onSide(frontZ, lampY - 0.07 * w), onSide(frontZ, lampY - 0.01 * w), onSide(frontZ - 0.06 * w, lampY - 0.01 * w)]);
  ctx.fillStyle = night > 0.2 ? 'rgb(255 236 190)' : paint('#f0a020');
  ctx.fill();
  fillPath(ctx, [onSide(-0.5 * L, 0.36 * w), onSide(-0.46 * L, 0.36 * w), onSide(-0.46 * L, 0.44 * w), onSide(-0.5 * L, 0.44 * w)]);
  ctx.fillStyle = night > 0.2 ? 'rgb(255 55 60)' : paint('#b3141e', 1.1);
  ctx.fill();
  // Taxi roof sign.
  if (profile.sign) {
    // A small box on the roof (the company "andon" lamp), lit at night.
    const roofPoints = profile.outline.filter(([, , role]) => role === 'roof' || role === 'windscreen');
    const roofY = Math.max(...profile.outline.map(([, y]) => y)) * w;
    const midZ = (roofPoints[0][0] + roofPoints.at(-1)[0]) / 2 * L;
    const { length: sl, height: sh, width: sw, color } = profile.sign;
    const x0 = -sw * w / 2;
    const x1 = sw * w / 2;
    const z0 = midZ - sl * L / 2;
    const z1 = midZ + sl * L / 2;
    const y0 = roofY;
    const y1 = roofY + sh * w;
    const faces = [
      { normal: [0, 1, 0], corners: [[x0, y1, z0], [x1, y1, z0], [x1, y1, z1], [x0, y1, z1]] },
      { normal: [0, 0, 1], corners: [[x0, y0, z1], [x1, y0, z1], [x1, y1, z1], [x0, y1, z1]] },
      { normal: [0, 0, -1], corners: [[x1, y0, z0], [x0, y0, z0], [x0, y1, z0], [x1, y1, z0]] },
      { normal: [nearSign, 0, 0], corners: [[nearX * sw, y0, z0], [nearX * sw, y0, z1], [nearX * sw, y1, z1], [nearX * sw, y1, z0]] }
    ];
    for (const face of faces) {
      const world = face.corners.map(corner => toWorld(corner));
      if (!facing(face.normal, world[0])) continue;
      fillPath(ctx, world.map(project));
      ctx.fillStyle = paint(color, (1 + night * 0.9) * (face.normal[1] ? 1.05 : 0.95));
      ctx.fill();
      ctx.strokeStyle = outlineColor;
      ctx.lineWidth = outlineWidth;
      ctx.stroke();
    }
    if (night > 0.2) {
      const [cx, cy] = project(toWorld([0, (y0 + y1) / 2, midZ]));
      const radius = Math.max(3, pixels * 0.25);
      const glow = ctx.createRadialGradient(cx, cy, 0, cx, cy, radius);
      glow.addColorStop(0, `rgb(255 244 200 / ${0.5 * night})`);
      glow.addColorStop(1, 'rgb(255 244 200 / 0)');
      ctx.fillStyle = glow;
      ctx.fillRect(cx - radius, cy - radius, radius * 2, radius * 2);
    }
  }
  if (profile.vacancy) {
    // The red "空車" (for hire) sign glowing behind the windscreen.
    const [fz, fy] = profile.window.at(-1);
    const red = [onSide((fz - 0.06) * L, (fy + 0.02) * w), onSide((fz - 0.01) * L, (fy + 0.02) * w), onSide((fz - 0.01) * L, (fy + 0.07) * w), onSide((fz - 0.06) * L, (fy + 0.07) * w)];
    fillPath(ctx, red);
    ctx.fillStyle = `rgb(255 60 50 / ${0.55 + 0.45 * night})`;
    ctx.fill();
  }
  // Near wheels.
  for (const z of wheelZ) drawWheel(ctx, frame, nearX * 1.002, z, wheelR, look, true);

  // Headlight pool on the road at night.
  if (!mirrored && night > 0.2) {
    const forward = [Math.sin(pose.heading), Math.cos(pose.heading)];
    const [fx, fy] = cam.project(pose.x + forward[0] * L * 0.9, 0, pose.z + forward[1] * L * 0.9);
    const radius = Math.max(4, pixels * 1.1);
    ctx.save();
    ctx.translate(fx, fy);
    ctx.scale(1, 0.35);
    const pool = ctx.createRadialGradient(0, 0, 0, 0, 0, radius);
    pool.addColorStop(0, `rgb(255 246 214 / ${0.28 * night})`);
    pool.addColorStop(1, 'rgb(255 246 214 / 0)');
    ctx.fillStyle = pool;
    ctx.fillRect(-radius, -radius, radius * 2, radius * 2);
    ctx.restore();
  }
}

function drawWetReflection(ctx, look, draw) {
  if (look.wet <= 0.05) return;
  ctx.save();
  ctx.globalAlpha *= 0.22 * look.wet;
  ctx.filter = 'blur(1px)';
  draw();
  ctx.restore();
}

/**
 * Draw a vehicle. pose: { x, z, heading, roll }. cam: { project(X, Y, Z) -> [sx, sy, scale], height }.
 * look: { light, tint, haze, hazeColor, night, wet, now }
 */
export function drawVehicle3D(ctx, vehicle, pose, cam, look, w) {
  if (PROFILES[vehicle.type]) {
    drawWetReflection(ctx, look, () => drawProfileCar(ctx, vehicle, pose, cam, look, w, true));
    drawProfileCar(ctx, vehicle, pose, cam, look, w);
    return;
  }
  const spec = VEHICLE_TYPES[vehicle.type];
  const paint = makePainter(look);
  const { parts, length } = partsFor(vehicle.type, w);
  const cos = Math.cos(pose.heading);
  const sin = Math.sin(pose.heading);
  const bob = Math.sin(look.now / 1000 * Math.PI * 2 * 1.6 + vehicle.seed) * w * 0.006;
  const roll = pose.roll ?? 0;
  // Vehicle frame -> world: rotate about y by heading (0 = +z), lean into turns.
  const toWorld = ([px, py, pz], body = true) => {
    const lean = body ? roll * (py / w) : 0;
    const lx = px + lean * w * 0.5;
    const ly = py + (body ? bob : 0);
    return [pose.x + lx * cos + pz * sin, ly, pose.z - lx * sin + pz * cos];
  };
  const normalOf = (worldCorners) => {
    const [a, b, c] = worldCorners;
    const u = [b[0] - a[0], b[1] - a[1], b[2] - a[2]];
    const v = [c[0] - a[0], c[1] - a[1], c[2] - a[2]];
    const n = [u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0]];
    const length = Math.hypot(...n) || 1;
    return n.map(component => component / length);
  };
  const pixels = w * cam.scaleAt(pose.z); // vehicle width on screen, in CSS pixels
  const outline = { color: `rgb(22 26 36 / ${0.5 * (1 - look.haze)})`, width: Math.max(0.4, pixels * 0.014) };
  const projectFace = corners => corners.map(corner => cam.project(...corner));
  const average = points => points.reduce((sum, p) => [sum[0] + p[0] / points.length, sum[1] + p[1] / points.length, sum[2] + p[2] / points.length], [0, 0, 0]);
  // Outward normal (pointing away from the part's centre, whatever the corner order) and back-face test.
  const visible = (world, partCentre) => {
    let n = normalOf(world);
    const centre = average(world);
    if (n[0] * (centre[0] - partCentre[0]) + n[1] * (centre[1] - partCentre[1]) + n[2] * (centre[2] - partCentre[2]) < 0) n = n.map(c => -c);
    const toCamera = [-centre[0], cam.height - centre[1], -centre[2]];
    return { facing: n[0] * toCamera[0] + n[1] * toCamera[1] + n[2] * toCamera[2] > 0, n };
  };
  const polygon = (points) => {
    ctx.beginPath();
    points.forEach(([x, y], index) => (index ? ctx.lineTo(x, y) : ctx.moveTo(x, y)));
    ctx.closePath();
  };
  const faceShade = n => 0.74 + 0.3 * Math.max(0, n[0] * LIGHT[0] + n[1] * LIGHT[1] + n[2] * LIGHT[2]) + 0.06 * n[1];

  // Soft contact shadow.
  const footprint = [[-0.56 * w, 0, -length * 0.54], [0.56 * w, 0, -length * 0.54], [0.56 * w, 0, length * 0.54], [-0.56 * w, 0, length * 0.54]]
    .map(point => cam.project(...toWorld(point, false)));
  ctx.save();
  ctx.filter = `blur(${Math.max(0.6, pixels * 0.05).toFixed(2)}px)`;
  polygon(footprint);
  ctx.fillStyle = `rgb(8 10 18 / ${0.42 * (1 - look.night * 0.35)})`;
  ctx.fill();
  ctx.restore();

  const drawPart = (part, mirrored) => {
    const partCentre = average(part.faces.flatMap(face => face.corners).map(corner => toWorld(corner, part.role !== 'tyre')));
    for (const face of part.faces) {
      const world = face.corners.map(corner => toWorld(corner, part.role !== 'tyre'));
      const used = mirrored ? world.map(([x, y, z]) => [x, -y, z]) : world;
      const { facing, n } = visible(world, partCentre);
      if (!facing) continue;
      const points = projectFace(used);
      polygon(points);
      const shade = faceShade(n);
      if (part.role === 'tyre') ctx.fillStyle = paint('#16181c', shade);
      else if (part.role === 'cab') ctx.fillStyle = paint('#e9ecef', shade);
      else if (part.role === 'sign') ctx.fillStyle = paint('#f6e7a6', 1 + look.night * 0.9);
      else ctx.fillStyle = paint(vehicle.color, part.role === 'cabin' ? shade * 0.92 : shade);
      ctx.fill();
      if (mirrored) continue;
      ctx.strokeStyle = outline.color;
      ctx.lineWidth = outline.width;
      ctx.stroke();
      decorate(part, face, world, n);
    }
  };

  const glassFill = (n) => {
    const sky = n[1] > 0.3 || look.night > 0.5 ? 0.5 : 1;
    return paint(look.night > 0.5 ? '#222a36' : sky > 0.6 ? '#7f97ad' : '#4d5d6e');
  };

  const lamp = (corners, u0, u1, v0, v1, color, glow) => {
    const quad = [onFace(corners, u0, v0), onFace(corners, u1, v0), onFace(corners, u1, v1), onFace(corners, u0, v1)];
    polygon(quad.map(point => cam.project(...point)));
    ctx.fillStyle = color;
    ctx.fill();
    if (glow > 0.05) {
      const centre = cam.project(...onFace(corners, (u0 + u1) / 2, (v0 + v1) / 2));
      const radius = Math.max(3, pixels * 0.35);
      const [r, g, b] = color.match(/\d+/g).map(Number);
      const gradient = ctx.createRadialGradient(centre[0], centre[1], 0, centre[0], centre[1], radius);
      gradient.addColorStop(0, `rgb(${r} ${g} ${b} / ${0.55 * glow})`);
      gradient.addColorStop(1, `rgb(${r} ${g} ${b} / 0)`);
      ctx.fillStyle = gradient;
      ctx.fillRect(centre[0] - radius, centre[1] - radius, radius * 2, radius * 2);
    }
  };

  function decorate(part, face, world, n) {
    const night = look.night;
    if (part.details === 'cabin' && face.name !== 'top') {
      // Windows inset into each side of the cabin.
      const inset = face.name === 'front' || face.name === 'back' ? [0.08, 0.92, 0.1, 0.88] : [0.06, 0.94, 0.12, 0.86];
      const glass = [onFace(world, inset[0], inset[2]), onFace(world, inset[1], inset[2]), onFace(world, inset[1], inset[3]), onFace(world, inset[0], inset[3])];
      polygon(glass.map(point => cam.project(...point)));
      ctx.fillStyle = glassFill(n);
      ctx.fill();
      if (face.name === 'left' || face.name === 'right') {
        // Pillar between the front and rear side windows.
        const a = cam.project(...onFace(world, 0.5, 0.1));
        const b = cam.project(...onFace(world, 0.5, 0.9));
        ctx.strokeStyle = paint(vehicle.color, 0.8);
        ctx.lineWidth = Math.max(0.6, outline.width * 1.6);
        ctx.beginPath();
        ctx.moveTo(...a);
        ctx.lineTo(...b);
        ctx.stroke();
      } else if (night < 0.5) {
        // A streak of sky on the windscreen.
        const s0 = cam.project(...onFace(world, 0.22, 0.85));
        const s1 = cam.project(...onFace(world, 0.36, 0.85));
        const s2 = cam.project(...onFace(world, 0.24, 0.15));
        const s3 = cam.project(...onFace(world, 0.1, 0.15));
        polygon([s0, s1, s2, s3]);
        ctx.fillStyle = 'rgb(255 255 255 / 0.16)';
        ctx.fill();
      }
    }
    const frontish = face.name === 'front';
    const backish = face.name === 'back';
    if ((part.details === 'body' || part.details === 'cab' || part.details === 'bus' || part.details === 'cargo') && (frontish || backish)) {
      if (part.details === 'cargo' && frontish) return;
      if (part.details === 'cab' && backish) return;
      const headlight = night > 0.2 ? 'rgb(255 250 228)' : paint('#e2e9ee', 1.1);
      const taillight = night > 0.2 ? 'rgb(255 55 60)' : paint('#b3141e', 1.15);
      const lampV = part.details === 'bus' || part.details === 'cargo' ? [0.04, 0.12] : part.details === 'cab' ? [0.08, 0.2] : [0.55, 0.78];
      // Faces are wound so u runs left→right as seen from outside the face.
      for (const [u0, u1] of [[0.05, 0.24], [0.76, 0.95]]) {
        lamp(world, u0, u1, lampV[0], lampV[1], frontish ? headlight : taillight, night);
      }
      if (part.details === 'body' && frontish) {
        const grille = [onFace(world, 0.3, 0.42), onFace(world, 0.7, 0.42), onFace(world, 0.7, 0.7), onFace(world, 0.3, 0.7)];
        polygon(grille.map(point => cam.project(...point)));
        ctx.fillStyle = paint('#1d2026');
        ctx.fill();
      }
      if (part.details === 'bus' || (part.details === 'cab' && frontish)) {
        // Big windscreen / rear window.
        const v = part.details === 'bus' ? (frontish ? [0.38, 0.84] : [0.6, 0.84]) : [0.45, 0.92];
        const glass = [onFace(world, 0.07, v[0]), onFace(world, 0.93, v[0]), onFace(world, 0.93, v[1]), onFace(world, 0.07, v[1])];
        polygon(glass.map(point => cam.project(...point)));
        ctx.fillStyle = glassFill(n);
        ctx.fill();
      }
      if (part.details === 'bus') {
        const sign = [onFace(world, 0.2, 0.88), onFace(world, 0.8, 0.88), onFace(world, 0.8, 0.96), onFace(world, 0.2, 0.96)];
        polygon(sign.map(point => cam.project(...point)));
        ctx.fillStyle = `rgb(255 168 40 / ${0.6 + night * 0.4})`;
        ctx.fill();
      }
      const plateV = part.details === 'body' ? [0.12, 0.36] : [0.02, 0.07];
      const plate = [onFace(world, 0.38, plateV[0]), onFace(world, 0.62, plateV[0]), onFace(world, 0.62, plateV[1]), onFace(world, 0.38, plateV[1])];
      polygon(plate.map(point => cam.project(...point)));
      ctx.fillStyle = paint(PLATES[spec.plate] ?? PLATES.white, 1 + night * 0.4);
      ctx.fill();
    }
    if (part.details === 'bus' && (face.name === 'left' || face.name === 'right')) {
      // Row of windows and the green band along the side.
      const band = [onFace(world, 0, 0.3), onFace(world, 1, 0.3), onFace(world, 1, 0.38), onFace(world, 0, 0.38)];
      polygon(band.map(point => cam.project(...point)));
      ctx.fillStyle = paint('#2f8a4c');
      ctx.fill();
      const windows = [onFace(world, 0.04, 0.5), onFace(world, 0.96, 0.5), onFace(world, 0.96, 0.85), onFace(world, 0.04, 0.85)];
      polygon(windows.map(point => cam.project(...point)));
      ctx.fillStyle = glassFill(n);
      ctx.fill();
    }
    if (part.details === 'cargo' && (face.name === 'left' || face.name === 'right')) {
      const stripe = [onFace(world, 0.05, 0.42), onFace(world, 0.95, 0.42), onFace(world, 0.95, 0.5), onFace(world, 0.05, 0.5)];
      polygon(stripe.map(point => cam.project(...point)));
      ctx.fillStyle = paint('#3a7bd5', 0.95);
      ctx.fill();
    }
  }

  drawWetReflection(ctx, look, () => {
    for (const part of parts) drawPart(part, true);
  });
  // Parts sorted far → near by distance to the camera (tyres before body; cabin last).
  const order = { tyre: 0, cargo: 1, paint: 1, cab: 2, cabin: 2, sign: 3 };
  const sorted = [...parts].sort((a, b) => {
    if (order[a.role] !== order[b.role]) return order[a.role] - order[b.role];
    const centre = part => toWorld(part.faces[0].corners[0]);
    const da = Math.hypot(centre(a)[0], centre(a)[2]);
    const db = Math.hypot(centre(b)[0], centre(b)[2]);
    return db - da;
  });
  // The cab of a truck sits in front of the cargo box: draw whichever is farther first.
  if (spec.truck) {
    const cargo = sorted.find(part => part.role === 'cargo');
    const cab = sorted.find(part => part.role === 'cab');
    const dist = part => {
      const p = toWorld(part.faces[0].corners[0]);
      return Math.hypot(p[0], p[2]);
    };
    if (dist(cab) > dist(cargo)) {
      sorted.splice(sorted.indexOf(cab), 1);
      sorted.splice(sorted.indexOf(cargo), 0, cab);
    }
  }
  // Trucks and buses get the same round wheels as the cars.
  const wheelFrame = makeFrame(vehicle, pose, cam, look, w);
  const nearSign = wheelFrame.facing([1, 0, 0], wheelFrame.toWorld([w / 2, 0.5 * w, 0])) ? 1 : -1;
  const wheelR = 0.19 * w;
  const wheelZ = spec.bus ? [-0.3 * length, 0.32 * length] : [-0.32 * length, 0.18 * length, 0.36 * length];
  for (const z of wheelZ) drawWheel(ctx, wheelFrame, -nearSign * w * 0.46, z, wheelR, look, false);
  for (const part of sorted) if (part.role !== 'tyre') drawPart(part, false);
  for (const z of wheelZ) drawWheel(ctx, wheelFrame, nearSign * w * 0.502, z, wheelR, look, true);

  // Headlight pool on the road / light streaks on the wet surface at night.
  if (look.night > 0.2) {
    const forward = [Math.sin(pose.heading), Math.cos(pose.heading)];
    const front = cam.project(pose.x + forward[0] * length * 0.9, 0, pose.z + forward[1] * length * 0.9);
    const radius = Math.max(4, pixels * 1.1);
    ctx.save();
    ctx.translate(front[0], front[1]);
    ctx.scale(1, 0.35);
    const pool = ctx.createRadialGradient(0, 0, 0, 0, 0, radius);
    pool.addColorStop(0, `rgb(255 246 214 / ${0.28 * look.night})`);
    pool.addColorStop(1, 'rgb(255 246 214 / 0)');
    ctx.fillStyle = pool;
    ctx.fillRect(-radius, -radius, radius * 2, radius * 2);
    ctx.restore();
  }
}

/** Light and haze for a vehicle at perspective scale `scale`. */
export function vehicleLook(env, light, scale, wet, now) {
  const { day, dusk, night } = env.periodWeights;
  const tint = [0, 1, 2].map(index => day + [1.06, 0.92, 0.84][index] * dusk + [0.86, 0.92, 1.1][index] * night);
  const t = clamp((scale - 0.06) / (0.5 - 0.06), 0, 1);
  const near = t * t * (3 - 2 * t);
  const haze = (1 - near) * (0.5 * day + 0.35 * dusk + 0.25 * night)
    + (env.weather.kind === 'fog' ? 0.3 * env.weather.intensity : 0);
  return {
    light,
    tint,
    haze: clamp(haze, 0, 0.75),
    hazeColor: night > 0.5 ? '#3a4560' : dusk > 0.5 ? '#e6b8a2' : '#c9d6e6',
    night: clamp(night + dusk * 0.45 + (env.weather.kind === 'storm' ? 0.3 : env.weather.kind === 'rain' ? 0.15 : 0) * env.weather.intensity, 0, 1),
    wet,
    now
  };
}

// ---- trains on the viaduct ------------------------------------------------------

export const TRAIN_LINES = {
  // Stainless cars with the line colour as a band below the windows.
  yamanote: { band: '#80c241', top: '#80c241' },
  keihinTohoku: { band: '#00b2e5', top: '#00b2e5' },
  sobu: { band: '#ffd400', top: '#ffd400' }
};

/**
 * One train car as a 3D box with windows, doors and the line colour.
 * car: { x, z, heading, railY, width, length, height, line, lead ('front' | 'rear' | null), seed }
 * Returns false when the car is too close to (or behind) the camera to draw.
 */
export function drawTrainCar(ctx, car, cam, look) {
  const paint = makePainter(look);
  const cos = Math.cos(car.heading);
  const sin = Math.sin(car.heading);
  const toWorld = ([lx, ly, lz]) => [car.x + lx * cos + lz * sin, ly, car.z - lx * sin + lz * cos];
  const rotate = ([nx, ny, nz]) => [nx * cos + nz * sin, ny, -nx * sin + nz * cos];
  const facing = (normal, point) => {
    const n = rotate(normal);
    return n[0] * -point[0] + n[1] * (cam.height - point[1]) + n[2] * -point[2] > 0;
  };
  const half = car.width / 2;
  const L = car.length / 2;
  const y0 = car.railY + 0.012;
  const y1 = car.railY + car.height;
  const corners = [[-half, y0, -L], [half, y0, -L], [half, y0, L], [-half, y0, L]].map(toWorld);
  if (corners.some(([, , z]) => z < 0.12)) return false;
  const project = point => cam.project(...point);
  const night = look.night;
  const line = TRAIN_LINES[car.line] ?? TRAIN_LINES.yamanote;
  const outline = `rgb(22 26 36 / ${0.45 * (1 - look.haze)})`;
  const quad = pts => {
    ctx.beginPath();
    pts.forEach(([x, y], index) => (index ? ctx.lineTo(x, y) : ctx.moveTo(x, y)));
    ctx.closePath();
  };
  // A point on a face given as (along 0..1, up 0..1).
  const sideX = facing([1, 0, 0], toWorld([half, (y0 + y1) / 2, 0])) ? half : -half;
  const onSide = (u, v) => project(toWorld([sideX * 1.001, y0 + (y1 - y0) * v, -L + 2 * L * u]));
  const sideShade = 0.86;

  // End faces (the cab of the lead car, or a plain end) if they face us.
  for (const [end, normal] of [[L, [0, 0, 1]], [-L, [0, 0, -1]]]) {
    const point = toWorld([0, (y0 + y1) / 2, end]);
    if (!facing(normal, point)) continue;
    const face = [[-half, y0, end], [half, y0, end], [half, y1, end], [-half, y1, end]].map(toWorld).map(project);
    quad(face);
    const cab = (car.lead === 'front' && end > 0) || (car.lead === 'rear' && end < 0);
    ctx.fillStyle = paint(cab ? '#2a2f36' : '#b9c0c6', cab ? 1 : 0.8);
    ctx.fill();
    ctx.strokeStyle = outline;
    ctx.stroke();
    if (cab) {
      const along = (u, v) => project(toWorld([-half + car.width * u, y0 + (y1 - y0) * v, end * 1.001]));
      quad([along(0.12, 0.45), along(0.88, 0.45), along(0.88, 0.85), along(0.12, 0.85)]);
      ctx.fillStyle = paint(night > 0.5 ? '#1c222b' : '#56687a');
      ctx.fill();
      for (const u of [0.15, 0.85]) {
        quad([along(u - 0.06, 0.25), along(u + 0.06, 0.25), along(u + 0.06, 0.33), along(u - 0.06, 0.33)]);
        ctx.fillStyle = night > 0.2 ? 'rgb(255 250 228)' : paint('#e8eef2', 1.1);
        ctx.fill();
      }
    }
  }

  // The long side.
  const side = [onSide(0, 0), onSide(1, 0), onSide(1, 1), onSide(0, 1)];
  const top = Math.min(side[2][1], side[3][1]);
  const bottom = Math.max(side[0][1], side[1][1]);
  const gradient = ctx.createLinearGradient(0, top, 0, bottom);
  gradient.addColorStop(0, paint('#dfe4e8', sideShade * 1.08));
  gradient.addColorStop(1, paint('#9ea6ad', sideShade));
  quad(side);
  ctx.fillStyle = gradient;
  ctx.fill();
  ctx.strokeStyle = outline;
  ctx.stroke();
  // Line colour: a band under the windows and a thin one along the top.
  quad([onSide(0, 0.36), onSide(1, 0.36), onSide(1, 0.44), onSide(0, 0.44)]);
  ctx.fillStyle = paint(line.band, 1);
  ctx.fill();
  quad([onSide(0, 0.9), onSide(1, 0.9), onSide(1, 0.94), onSide(0, 0.94)]);
  ctx.fillStyle = paint(line.top, 0.95);
  ctx.fill();
  // Windows (lit at night) between four sets of doors.
  const glass = night > 0.4 ? `rgb(255 238 196 / ${0.55 + 0.4 * night})` : paint('#4b5c6d');
  const doors = [0.12, 0.37, 0.63, 0.88];
  const windows = [[0.02, 0.09], [0.16, 0.33], [0.41, 0.59], [0.67, 0.84], [0.91, 0.98]];
  for (const [u0, u1] of windows) {
    quad([onSide(u0, 0.5), onSide(u1, 0.5), onSide(u1, 0.82), onSide(u0, 0.82)]);
    ctx.fillStyle = glass;
    ctx.fill();
  }
  for (const u of doors) {
    quad([onSide(u - 0.03, 0.06), onSide(u + 0.03, 0.06), onSide(u + 0.03, 0.86), onSide(u - 0.03, 0.86)]);
    ctx.fillStyle = paint('#c3c9ce', sideShade * 0.95);
    ctx.fill();
    ctx.strokeStyle = outline;
    ctx.lineWidth = 0.6;
    ctx.stroke();
    quad([onSide(u - 0.022, 0.5), onSide(u + 0.022, 0.5), onSide(u + 0.022, 0.8), onSide(u - 0.022, 0.8)]);
    ctx.fillStyle = glass;
    ctx.fill();
  }
  return true;
}
