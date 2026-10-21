// Street traffic seen straight down the road (Akihabara): cars, kei cars, taxis,
// trucks and buses, painted in a soft cel-shaded style to sit in the anime scenes.
//
// Positions use real perspective: each vehicle has a distance `z` (1 = the reference
// row of the road), moves at a constant speed, and is drawn at scale 1 / z. So far-off
// traffic creeps along and grows smoothly as it comes closer, instead of sliding.

export const VEHICLE_TYPES = {
  sedan: { weight: 3, width: 1, body: 0.36, cabin: 0.3, cabinTop: 0.68, cabinBase: 0.86, plate: 'white', lamps: 'wide' },
  kei: { weight: 2.6, width: 0.84, body: 0.4, cabin: 0.5, cabinTop: 0.84, cabinBase: 0.92, plate: 'yellow', lamps: 'tall' },
  minivan: { weight: 1.6, width: 1, body: 0.44, cabin: 0.46, cabinTop: 0.82, cabinBase: 0.92, plate: 'white', lamps: 'tall' },
  taxi: { weight: 1.4, width: 0.95, body: 0.4, cabin: 0.4, cabinTop: 0.78, cabinBase: 0.9, plate: 'green', lamps: 'wide', sign: true },
  truck: { weight: 0.6, width: 1.1, plate: 'green' },
  bus: { weight: 0.3, width: 1.22, plate: 'green' }
};

const COLORS = {
  sedan: ['#f4f5f7', '#1d1f24', '#c4c9cf', '#2b3a67', '#b3202a', '#30343b', '#5b7c99', '#e7e2d4'],
  kei: ['#f4f5f7', '#e8d9b5', '#8fc3c0', '#e9a6b0', '#c4c9cf', '#3b3f46', '#f2c230', '#9cb86a'],
  minivan: ['#f4f5f7', '#1d1f24', '#c4c9cf', '#30343b', '#6d7a86', '#e7e2d4'],
  taxi: ['#1d2740', '#1d2740', '#1d2740', '#f2c230', '#e9e4d6', '#2e6b4f'],
  truck: ['#eef0f2'],
  bus: ['#f1f2ee']
};

const PLATES = { white: '#f2f2ec', yellow: '#f1cf34', green: '#1f6b3a' };
const NEAREST = 0.33; // this close, a vehicle is rushing out of the bottom of the picture
const FARTHEST = 15;

const clamp = (value, min, max) => Math.min(max, Math.max(min, value));
const smoothstep = (edge0, edge1, value) => {
  const t = clamp((value - edge0) / (edge1 - edge0), 0, 1);
  return t * t * (3 - 2 * t);
};

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

/** 0..1 opacity: fades in from the distance, and out in the instant it sweeps past the camera. */
export function vehicleAlpha(z) {
  return smoothstep(FARTHEST, FARTHEST - 2.5, z) * smoothstep(NEAREST, 0.42, z);
}

/** Where a vehicle is at `now`: its distance, and whether it has left the road. */
export function vehiclePosition(vehicle, now) {
  const elapsed = Math.max(0, (now - vehicle.start) / 1000);
  const z = vehicle.direction === 'away'
    ? vehicle.z0 + vehicle.speed * elapsed
    : vehicle.z0 - vehicle.speed * elapsed;
  const done = vehicle.direction === 'away' ? z >= FARTHEST : z <= NEAREST;
  return { z, scale: 1 / Math.max(z, 0.05), done };
}

/**
 * New vehicle for a lane. `ahead` is the last vehicle still on that lane: the newcomer
 * never drives faster than it, so traffic keeps its spacing and nobody drives through
 * anybody. Returns null when the lane is too crowded at its entry point.
 */
export function spawnVehicle(lane, now, random = Math.random, ahead = null) {
  const away = lane.direction === 'away';
  const z0 = away ? NEAREST : FARTHEST;
  if (ahead) {
    const { z } = vehiclePosition(ahead, now);
    const gap = away ? z - z0 : z0 - z;
    if (gap < (away ? 1.4 : 4)) return null;
  }
  const type = pickType(random);
  const colors = COLORS[type];
  let speed = (type === 'bus' || type === 'truck' ? 0.95 : 1.15) * (0.85 + random() * 0.35);
  if (ahead) speed = Math.min(speed, ahead.speed);
  return {
    type,
    typeWidth: VEHICLE_TYPES[type].width,
    color: colors[Math.floor(random() * colors.length)],
    direction: away ? 'away' : 'toward',
    lane: lane.index ?? 0,
    z0,
    speed,
    start: now,
    seed: random() * 1000
  };
}

// ---- painting ---------------------------------------------------------------

function hexToRgb(hex) {
  const value = parseInt(hex.slice(1), 16);
  return [(value >> 16) & 255, (value >> 8) & 255, value & 255];
}

function makePainter(light, tint, haze, hazeColor) {
  const hazeRgb = hexToRgb(hazeColor);
  return (hex, factor = 1, alpha = 1) => {
    const rgb = typeof hex === 'string' ? hexToRgb(hex) : hex;
    const out = rgb.map((channel, index) => {
      const lit = channel * light * factor * tint[index];
      return Math.round(clamp(lit + (hazeRgb[index] * light * tint[index] - lit) * haze, 0, 255));
    });
    return alpha >= 1 ? `rgb(${out[0]} ${out[1]} ${out[2]})` : `rgb(${out[0]} ${out[1]} ${out[2]} / ${alpha})`;
  };
}

/** Rounded trapezoid standing on `bottom`, centred on `cx`. */
function trapezoid(ctx, cx, bottom, bottomWidth, topWidth, height, radius) {
  const top = bottom - height;
  const r = Math.min(radius, height / 2, topWidth / 2);
  const bl = cx - bottomWidth / 2;
  const br = cx + bottomWidth / 2;
  const tl = cx - topWidth / 2;
  const tr = cx + topWidth / 2;
  ctx.beginPath();
  ctx.moveTo(bl + r * 0.4, bottom);
  ctx.lineTo(br - r * 0.4, bottom);
  ctx.quadraticCurveTo(br, bottom, br, bottom - r * 0.6);
  ctx.lineTo(tr, top + r);
  ctx.quadraticCurveTo(tr, top, tr - r, top);
  ctx.lineTo(tl + r, top);
  ctx.quadraticCurveTo(tl, top, tl, top + r);
  ctx.lineTo(bl, bottom - r * 0.6);
  ctx.quadraticCurveTo(bl, bottom, bl + r * 0.4, bottom);
  ctx.closePath();
}

function roundRect(ctx, x, y, w, h, r) {
  ctx.beginPath();
  ctx.roundRect(x, y, w, h, Math.min(r, w / 2, h / 2));
}

function bodyFill(ctx, paint, color, top, bottom) {
  const gradient = ctx.createLinearGradient(0, top, 0, bottom);
  gradient.addColorStop(0, paint(color, 1.2));
  gradient.addColorStop(0.35, paint(color, 1.02));
  gradient.addColorStop(1, paint(color, 0.66));
  return gradient;
}

function glassFill(ctx, paint, top, bottom, night) {
  const gradient = ctx.createLinearGradient(0, top, 0, bottom);
  // Daytime glass mirrors the sky; at night it goes dark with a faint cabin glow.
  gradient.addColorStop(0, paint(night > 0.5 ? '#2a3442' : '#a9c0d6'));
  gradient.addColorStop(0.55, paint(night > 0.5 ? '#1a212b' : '#56697c'));
  gradient.addColorStop(1, paint('#20262e'));
  return gradient;
}

function glassHighlight(ctx, left, top, width, height, alpha) {
  if (alpha <= 0.01) return;
  ctx.fillStyle = `rgb(255 255 255 / ${alpha})`;
  ctx.beginPath();
  ctx.moveTo(left + width * 0.18, top);
  ctx.lineTo(left + width * 0.36, top);
  ctx.lineTo(left + width * 0.2, top + height);
  ctx.lineTo(left + width * 0.02, top + height);
  ctx.closePath();
  ctx.fill();
}

function lamp(ctx, x, y, w, h, color, on, glowRadius) {
  roundRect(ctx, x - w / 2, y - h / 2, w, h, h * 0.45);
  ctx.fillStyle = color;
  ctx.fill();
  if (on > 0.05) {
    const [r, g, b] = color.match(/\d+/g).map(Number);
    const glow = ctx.createRadialGradient(x, y, 0, x, y, glowRadius);
    glow.addColorStop(0, `rgb(${r} ${g} ${b} / ${0.55 * on})`);
    glow.addColorStop(1, `rgb(${r} ${g} ${b} / 0)`);
    ctx.fillStyle = glow;
    ctx.fillRect(x - glowRadius, y - glowRadius, glowRadius * 2, glowRadius * 2);
  }
}

function plate(ctx, paint, cx, y, w, kind, night) {
  const pw = w * 0.22;
  const ph = w * 0.1;
  roundRect(ctx, cx - pw / 2, y, pw, ph, ph * 0.18);
  ctx.fillStyle = paint(PLATES[kind] || PLATES.white, 1 + night * 0.4);
  ctx.fill();
  if (w > 26) {
    ctx.fillStyle = paint(kind === 'green' ? '#f2f2ec' : '#1f6b3a', 1, 0.8);
    ctx.fillRect(cx - pw * 0.3, y + ph * 0.55, pw * 0.6, ph * 0.18);
  }
}

function tyres(ctx, paint, cx, ground, w, track) {
  ctx.fillStyle = paint('#15171b');
  for (const side of [-1, 1]) {
    roundRect(ctx, cx + side * w * track - w * 0.085, ground - w * 0.17, w * 0.17, w * 0.17, w * 0.04);
    ctx.fill();
  }
}

function drawCar(ctx, v, cx, ground, w, paint, look) {
  const spec = VEHICLE_TYPES[v.type];
  const front = v.direction === 'toward';
  const { night, outline } = look;
  tyres(ctx, paint, cx, ground, w, 0.36);
  // Bumper / under-body.
  roundRect(ctx, cx - w * 0.49, ground - w * 0.22, w * 0.98, w * 0.13, w * 0.05);
  ctx.fillStyle = paint('#2a2d33');
  ctx.fill();
  const bodyBottom = ground - w * 0.1;
  const bodyTop = bodyBottom - spec.body * w;
  const cabinTop = bodyTop - spec.cabin * w;
  // Cabin (pillars), then glass inset.
  trapezoid(ctx, cx, bodyTop + w * 0.02, spec.cabinBase * w, spec.cabinTop * w, spec.cabin * w + w * 0.02, w * 0.09);
  ctx.fillStyle = bodyFill(ctx, paint, v.color, cabinTop, bodyTop);
  ctx.fill();
  ctx.lineWidth = outline.width;
  ctx.strokeStyle = outline.color;
  ctx.stroke();
  const glassTopW = spec.cabinTop * w - w * 0.08;
  const glassBottomW = spec.cabinBase * w - w * 0.1;
  const glassH = spec.cabin * w - w * 0.07;
  trapezoid(ctx, cx, bodyTop - w * 0.025, glassBottomW, glassTopW, glassH, w * 0.06);
  ctx.fillStyle = glassFill(ctx, paint, cabinTop, bodyTop, night);
  ctx.fill();
  glassHighlight(ctx, cx - glassBottomW / 2, bodyTop - w * 0.025 - glassH, glassBottomW, glassH, 0.16 * (1 - night) + 0.04);
  // Door mirrors poke out either side of the windscreen.
  for (const side of [-1, 1]) {
    roundRect(ctx, cx + side * (spec.cabinBase * w / 2 + w * 0.035) - w * 0.045, bodyTop - w * 0.07, w * 0.09, w * 0.06, w * 0.02);
    ctx.fillStyle = paint(v.color, 0.85);
    ctx.fill();
    ctx.lineWidth = outline.width;
    ctx.strokeStyle = outline.color;
    ctx.stroke();
  }
  // Body.
  trapezoid(ctx, cx, bodyBottom, w, w * 0.96, spec.body * w, w * 0.08);
  ctx.fillStyle = bodyFill(ctx, paint, v.color, bodyTop, bodyBottom);
  ctx.fill();
  ctx.stroke();
  // Shoulder highlight catches the sky.
  ctx.strokeStyle = `rgb(255 255 255 / ${0.32 * (1 - night * 0.7)})`;
  ctx.lineWidth = Math.max(0.6, w * 0.012);
  ctx.beginPath();
  ctx.moveTo(cx - w * 0.42, bodyTop + w * 0.025);
  ctx.lineTo(cx + w * 0.42, bodyTop + w * 0.025);
  ctx.stroke();
  // Taxi roof sign.
  if (spec.sign) {
    roundRect(ctx, cx - w * 0.12, cabinTop - w * 0.075, w * 0.24, w * 0.08, w * 0.03);
    ctx.fillStyle = paint('#f6e7a6', 1 + night * 0.9);
    ctx.fill();
    ctx.strokeStyle = outline.color;
    ctx.lineWidth = outline.width;
    ctx.stroke();
  }
  const lampY = bodyTop + spec.body * w * 0.3;
  if (front) {
    // Grille and headlights.
    roundRect(ctx, cx - w * 0.2, bodyTop + spec.body * w * 0.42, w * 0.4, spec.body * w * 0.28, w * 0.04);
    ctx.fillStyle = paint('#1d2026');
    ctx.fill();
    for (const side of [-1, 1]) {
      lamp(ctx, cx + side * w * 0.34, lampY, w * 0.2, w * 0.075, night > 0.2 ? 'rgb(255 250 228)' : paint('#dfe7ec', 1.1), night, w * 0.45);
    }
    plate(ctx, paint, cx, bodyBottom - w * 0.11, w, spec.plate, night);
  } else {
    for (const side of [-1, 1]) {
      const tall = spec.lamps === 'tall';
      lamp(ctx, cx + side * w * (tall ? 0.42 : 0.35), tall ? bodyTop - w * 0.02 : lampY,
        tall ? w * 0.08 : w * 0.2, tall ? w * 0.2 : w * 0.075,
        night > 0.2 ? 'rgb(255 55 60)' : paint('#b3141e', 1.15), night, w * 0.4);
    }
    plate(ctx, paint, cx, bodyTop + spec.body * w * 0.45, w, spec.plate, night);
  }
}

function drawTruck(ctx, v, cx, ground, w, paint, look) {
  const front = v.direction === 'toward';
  const { night, outline } = look;
  tyres(ctx, paint, cx, ground, w, 0.38);
  roundRect(ctx, cx - w * 0.48, ground - w * 0.24, w * 0.96, w * 0.12, w * 0.03);
  ctx.fillStyle = paint('#25282d');
  ctx.fill();
  const boxBottom = ground - w * 0.18;
  const boxTop = boxBottom - w * 1.02;
  if (front) {
    // Box shows above the cab.
    roundRect(ctx, cx - w * 0.47, boxTop, w * 0.94, w * 0.4, w * 0.03);
    ctx.fillStyle = bodyFill(ctx, paint, v.color, boxTop, boxTop + w * 0.4);
    ctx.fill();
    ctx.strokeStyle = outline.color;
    ctx.lineWidth = outline.width;
    ctx.stroke();
    const cabTop = boxTop + w * 0.3;
    trapezoid(ctx, cx, boxBottom + w * 0.02, w * 0.92, w * 0.84, boxBottom - cabTop, w * 0.07);
    ctx.fillStyle = bodyFill(ctx, paint, '#e9ecef', cabTop, boxBottom);
    ctx.fill();
    ctx.stroke();
    trapezoid(ctx, cx, cabTop + w * 0.36, w * 0.8, w * 0.74, w * 0.3, w * 0.04);
    ctx.fillStyle = glassFill(ctx, paint, cabTop, cabTop + w * 0.36, night);
    ctx.fill();
    glassHighlight(ctx, cx - w * 0.4, cabTop + w * 0.06, w * 0.8, w * 0.3, 0.14 * (1 - night) + 0.04);
    for (const side of [-1, 1]) lamp(ctx, cx + side * w * 0.34, boxBottom - w * 0.12, w * 0.16, w * 0.07, night > 0.2 ? 'rgb(255 250 228)' : paint('#dfe7ec', 1.1), night, w * 0.45);
    plate(ctx, paint, cx, boxBottom - w * 0.12, w, 'green', night);
    return;
  }
  // Rear: a big roller-shutter box.
  roundRect(ctx, cx - w * 0.5, boxTop, w, boxBottom - boxTop, w * 0.03);
  ctx.fillStyle = bodyFill(ctx, paint, v.color, boxTop, boxBottom);
  ctx.fill();
  ctx.strokeStyle = outline.color;
  ctx.lineWidth = outline.width;
  ctx.stroke();
  ctx.strokeStyle = paint('#9aa1a8', 1, 0.55);
  ctx.lineWidth = Math.max(0.5, w * 0.008);
  for (let index = 1; index < 9; index += 1) {
    const y = boxTop + (boxBottom - boxTop) * index / 9;
    ctx.beginPath();
    ctx.moveTo(cx - w * 0.44, y);
    ctx.lineTo(cx + w * 0.44, y);
    ctx.stroke();
  }
  for (const side of [-1, 1]) lamp(ctx, cx + side * w * 0.4, ground - w * 0.18, w * 0.14, w * 0.06, night > 0.2 ? 'rgb(255 55 60)' : paint('#b3141e', 1.15), night, w * 0.35);
  plate(ctx, paint, cx, ground - w * 0.235, w, 'green', night);
}

function drawBus(ctx, v, cx, ground, w, paint, look) {
  const front = v.direction === 'toward';
  const { night, outline } = look;
  tyres(ctx, paint, cx, ground, w, 0.38);
  const bottom = ground - w * 0.08;
  const top = bottom - w * 1.18;
  roundRect(ctx, cx - w * 0.5, top, w, bottom - top, w * 0.08);
  ctx.fillStyle = bodyFill(ctx, paint, v.color, top, bottom);
  ctx.fill();
  ctx.strokeStyle = outline.color;
  ctx.lineWidth = outline.width;
  ctx.stroke();
  // City-bus green band.
  ctx.fillStyle = paint('#2f8a4c');
  ctx.fillRect(cx - w * 0.5, bottom - w * 0.36, w, w * 0.1);
  // Destination sign glows orange.
  roundRect(ctx, cx - w * 0.34, top + w * 0.05, w * 0.68, w * 0.11, w * 0.02);
  ctx.fillStyle = paint('#1a1c20');
  ctx.fill();
  ctx.fillStyle = `rgb(255 168 40 / ${0.55 + night * 0.45})`;
  ctx.fillRect(cx - w * 0.26, top + w * 0.085, w * 0.52, w * 0.04);
  const glassTop = top + w * 0.2;
  const glassBottom = front ? bottom - w * 0.42 : top + w * 0.5;
  roundRect(ctx, cx - w * 0.44, glassTop, w * 0.88, glassBottom - glassTop, w * 0.04);
  ctx.fillStyle = glassFill(ctx, paint, glassTop, glassBottom, night);
  ctx.fill();
  glassHighlight(ctx, cx - w * 0.44, glassTop, w * 0.88, glassBottom - glassTop, 0.13 * (1 - night) + 0.04);
  const lampColor = front ? (night > 0.2 ? 'rgb(255 250 228)' : paint('#dfe7ec', 1.1)) : (night > 0.2 ? 'rgb(255 55 60)' : paint('#b3141e', 1.15));
  for (const side of [-1, 1]) lamp(ctx, cx + side * w * 0.38, bottom - w * 0.18, w * (front ? 0.14 : 0.07), w * (front ? 0.07 : 0.16), lampColor, night, w * 0.4);
  plate(ctx, paint, cx, bottom - w * 0.2, w, 'green', night);
}

/**
 * Paint one vehicle standing on (cx, ground) with bumper width `w` (CSS pixels).
 * look: { light, tint, haze, hazeColor, night, wet, now }
 */
export function drawVehicle(ctx, v, cx, ground, w, look) {
  const paint = makePainter(look.light, look.tint, look.haze, look.hazeColor);
  const full = { ...look, outline: { color: `rgb(22 26 36 / ${0.55 * (1 - look.haze)})`, width: Math.max(0.5, w * 0.014) } };
  // Suspension: the body floats a touch over the road.
  const bob = Math.sin(look.now / 1000 * Math.PI * 2 * 1.7 + v.seed) * w * 0.006
    + Math.sin(look.now / 1000 * Math.PI * 2 * 0.53 + v.seed * 1.7) * w * 0.004;
  ctx.save();
  ctx.translate(0, bob);
  if (v.type === 'truck') drawTruck(ctx, v, cx, ground - bob, w, paint, full);
  else if (v.type === 'bus') drawBus(ctx, v, cx, ground - bob, w, paint, full);
  else drawCar(ctx, v, cx, ground - bob, w, paint, full);
  ctx.restore();
}

/** Soft contact shadow, plus light pooling on the road from headlights at night. */
export function drawVehicleGround(ctx, v, cx, ground, w, look) {
  ctx.save();
  ctx.translate(cx, ground);
  ctx.scale(1, 0.2);
  const strength = 1 - look.night * 0.35;
  const shadow = ctx.createRadialGradient(0, 0, 0, 0, 0, w * 0.64);
  shadow.addColorStop(0, `rgb(8 10 18 / ${0.62 * strength})`);
  shadow.addColorStop(0.65, `rgb(8 10 18 / ${0.34 * strength})`);
  shadow.addColorStop(1, 'rgb(8 10 18 / 0)');
  ctx.fillStyle = shadow;
  ctx.fillRect(-w * 0.7, -w * 0.7, w * 1.4, w * 1.4);
  ctx.restore();
  // Tight contact shadow right under the body so the tyres sit on the road.
  ctx.fillStyle = `rgb(6 8 14 / ${0.55 * strength})`;
  ctx.beginPath();
  ctx.ellipse(cx, ground - w * 0.004, w * 0.47, w * 0.028, 0, 0, Math.PI * 2);
  ctx.fill();
  if (look.night > 0.2 && v.direction === 'toward') {
    // Headlight pool on the road in front of (below) the car.
    ctx.save();
    ctx.translate(cx, ground + w * 0.35);
    ctx.scale(1, 0.32);
    const pool = ctx.createRadialGradient(0, 0, 0, 0, 0, w * 1.1);
    pool.addColorStop(0, `rgb(255 246 214 / ${0.3 * look.night})`);
    pool.addColorStop(1, 'rgb(255 246 214 / 0)');
    ctx.fillStyle = pool;
    ctx.fillRect(-w * 1.1, -w * 1.1, w * 2.2, w * 2.2);
    ctx.restore();
  }
  if (look.night > 0.2 && look.wet > 0.05) {
    // Long streaks of lamp light on the wet road.
    const color = v.direction === 'toward' ? '255 246 214' : '255 55 60';
    for (const side of [-1, 1]) {
      const x = cx + side * w * 0.35;
      const streak = ctx.createLinearGradient(0, ground, 0, ground + w * 1.2);
      streak.addColorStop(0, `rgb(${color} / ${0.4 * look.night * look.wet})`);
      streak.addColorStop(1, `rgb(${color} / 0)`);
      ctx.fillStyle = streak;
      ctx.fillRect(x - w * 0.05, ground, w * 0.1, w * 1.2);
    }
  }
}

/** Light and haze for a vehicle at perspective scale `scale`. */
export function vehicleLook(env, light, scale, wet, now) {
  const { day, dusk, night } = env.periodWeights;
  const tint = [0, 1, 2].map(index => day + [1.06, 0.92, 0.84][index] * dusk + [0.86, 0.92, 1.1][index] * night);
  const haze = (1 - smoothstep(0.08, 0.7, scale)) * (0.5 * day + 0.35 * dusk + 0.25 * night)
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

export const ROAD_LIMITS = { NEAREST, FARTHEST };
