// Drawing the Shibuya crossing's people, cars and pedestrian lights (see crowd.js).
//
// People are painted in anime cel style in perspective: a 1.6 m person standing where
// Miku's feet are is exactly as tall as she is, so the crowd and Miku share one scale.

import { drawVehicle3D, makeVehicle, vehicleLook } from './vehicles.js';

const clamp = (value, min, max) => Math.min(max, Math.max(min, value));

function rgb(hex) {
  const value = parseInt(hex.slice(1), 16);
  return [(value >> 16) & 255, (value >> 8) & 255, value & 255];
}

/** A colour lit by `light` (0..1), tinted, and faded into the haze with distance. */
function lit(hex, look, extra = 1) {
  const [r, g, b] = rgb(hex);
  const mix = (channel, index) => {
    const k = look.light * (Array.isArray(extra) ? extra[index] : extra);
    const shaded = Math.min(255, channel * k * look.tint[index]);
    return Math.round(shaded * (1 - look.haze) + look.hazeRgb[index] * look.haze);
  };
  return `rgb(${mix(r, 0)} ${mix(g, 1)} ${mix(b, 2)})`;
}

/**
 * camera: { horizon, vx, eye (m), focal } in the scene image's normalised coordinates.
 * view: { px, py, size } map normalised image coordinates to canvas pixels.
 */
export function scrambleCamera(camera, view) {
  const hpx = view.size(1);
  const vx = view.px(camera.vx);
  const vy = view.py(camera.horizon);
  const scaleAt = z => camera.focal / Math.max(z, 0.3) * hpx;
  return {
    height: camera.eye,
    scaleAt,
    project: (x, y, z) => {
      const s = scaleAt(z);
      return [vx + x * s, vy + (camera.eye - y) * s];
    }
  };
}

function drawShadow(ctx, x, y, width, alpha) {
  ctx.save();
  ctx.globalAlpha *= alpha;
  ctx.fillStyle = 'rgb(10 12 18)';
  ctx.beginPath();
  ctx.ellipse(x, y, width, width * 0.22, 0, 0, Math.PI * 2);
  ctx.fill();
  ctx.restore();
}

// ---- people ------------------------------------------------------------
//
// Painted the way background characters are in anime, to sit with the painted street and
// Miku's toon shading: flat colour, one hard shadow tone on the side away from the light
// (cool, like the shade on her toon material), and thin outlines a darker shade of each
// part's own colour rather than black.

/** Base, shadow and outline colours for one part. */
function tones(hex, look, extra = 1) {
  return {
    base: lit(hex, look, extra),
    shade: lit(hex, look, [0.68 * extra, 0.7 * extra, 0.82 * extra]),
    line: lit(hex, look, [0.34 * extra, 0.31 * extra, 0.38 * extra]),
    high: lit(hex, look, Math.min(1.35, 1.25 * extra))
  };
}

/**
 * Fill a part with its tones. The outline goes down first at double width so the fill
 * covers its inner half (and any seams between overlapping pieces of the same part);
 * the shadow is the part minus a copy of itself shifted towards the light.
 */
function paint(ctx, path, t, line, shift) {
  if (line > 0) {
    ctx.strokeStyle = t.line;
    ctx.lineWidth = line * 2;
    ctx.lineJoin = 'round';
    ctx.stroke(path);
  }
  ctx.save();
  ctx.clip(path);
  ctx.fillStyle = t.shade;
  ctx.fill(path);
  ctx.translate(-shift, -shift * 0.35);
  ctx.fillStyle = t.base;
  ctx.fill(path);
  ctx.restore();
}

/** A tapered capsule from (x0, y0) to (x1, y1), w0 and w1 wide at the ends. */
function capsule(path, x0, y0, w0, x1, y1, w1) {
  const angle = Math.atan2(y1 - y0, x1 - x0);
  const nx = -Math.sin(angle);
  const ny = Math.cos(angle);
  path.moveTo(x0 + nx * w0 / 2, y0 + ny * w0 / 2);
  path.lineTo(x1 + nx * w1 / 2, y1 + ny * w1 / 2);
  path.arc(x1, y1, w1 / 2, angle + Math.PI / 2, angle - Math.PI / 2, true);
  path.lineTo(x0 - nx * w0 / 2, y0 - ny * w0 / 2);
  path.arc(x0, y0, w0 / 2, angle - Math.PI / 2, angle + Math.PI / 2, true);
  path.closePath();
}

/**
 * Points of a limb from (x, y): segments of [length, angle]; angle 0 hangs straight down,
 * positive swings towards `dir` on screen. `side` (0..1) is how much of the swing shows
 * (none when they walk straight towards or away from us).
 */
function limbPoints(x, y, segments, dir, side) {
  const points = [[x, y]];
  for (const [length, angle] of segments) {
    const [px, py] = points.at(-1);
    points.push([px + Math.sin(angle) * length * side * dir, py + Math.cos(angle) * length]);
  }
  return points;
}

function limbPath(points, widths) {
  const path = new Path2D();
  for (let i = 0; i < points.length - 1; i += 1) {
    capsule(path, points[i][0], points[i][1], widths[i], points[i + 1][0], points[i + 1][1], widths[i + 1]);
  }
  return path;
}

/** Points around an ellipse from angle a0 to a1 (radians, canvas convention). */
function arcPoints(cx, cy, rx, ry, a0, a1, steps = 14) {
  const points = [];
  for (let i = 0; i <= steps; i += 1) {
    const a = a0 + (a1 - a0) * i / steps;
    points.push([cx + Math.cos(a) * rx, cy + Math.sin(a) * ry]);
  }
  return points;
}

function polygon(points) {
  const path = new Path2D();
  points.forEach(([px, py], index) => (index ? path.lineTo(px, py) : path.moveTo(px, py)));
  path.closePath();
  return path;
}

/**
 * One person, feet at (x, y), `h` pixels for 1.6 m. Proportions a little towards anime
 * (a slightly larger head) so they sit next to Miku; faces only when close enough to see.
 */
export function drawPerson(ctx, person, x, y, h, look, umbrellas) {
  if (h < 3) return;
  const p = person.look;
  const H = h * (p.height / 1.6);
  const walking = person.speed > 0.05;
  // How much we see them from the side (0 = walking straight towards or away from us).
  const side = Math.abs(Math.sin(person.heading));
  const towards = Math.cos(person.heading) < 0;
  const dir = Math.sin(person.heading) >= 0 ? 1 : -1;
  const sideOn = side > 0.4;
  const phase = person.phase * Math.PI;
  const swing = walking ? Math.sin(phase) : 0;
  const bob = walking ? Math.abs(Math.cos(phase)) * H * 0.012 : Math.sin(p.sway + person.phase * 0.3) * H * 0.003;
  const build = p.build;
  const narrow = 1 - side * 0.38;
  const hipY = y - H * 0.5 - bob;
  const waistY = y - H * 0.6 - bob;
  const shoulderY = y - H * 0.81 - bob;
  const neckY = y - H * 0.85 - bob;
  const shoulderW = H * (p.skirt ? 0.108 : 0.125) * build * narrow;
  const waistW = H * (p.skirt ? 0.072 : 0.09) * build * narrow;
  const hipW = H * (p.skirt ? 0.092 : 0.088) * build * narrow;
  const headH = H * 0.14;
  const headW = H * 0.064;
  const headY = y - H + headH * 0.5 - bob;
  const headX = x + dir * side * headW * 0.08;

  if (H < 14) {
    // Far away: a few strokes are enough.
    drawShadow(ctx, x, y, H * 0.15, 0.3 * look.light);
    ctx.fillStyle = lit(p.skirt ? p.tights : p.legs, look);
    ctx.fillRect(x - waistW * 0.8, hipY, waistW * 1.6, y - hipY);
    ctx.fillStyle = lit(p.coat, look);
    ctx.fillRect(x - shoulderW, shoulderY, shoulderW * 2, y - H * p.hem - shoulderY);
    ctx.fillStyle = lit(p.hair, look);
    ctx.beginPath();
    ctx.arc(x, headY, H * 0.07, 0, Math.PI * 2);
    ctx.fill();
    if (umbrellas) drawUmbrella(ctx, x, y - H * 1.04 - bob, H, p.umbrella, look);
    return;
  }

  const line = H < 30 ? 0 : clamp(H * 0.0045, 0.6, 3);
  const shift = H * 0.022;
  drawShadow(ctx, x, y, H * 0.16, 0.3 * look.light);

  // Long hair falls behind the shoulders when we see their front.
  const hairT = tones(p.hair, look);
  const hairLength = p.hairLength === 2 ? H * 0.17 : p.hairLength === 1 ? H * 0.07 : 0;
  if (hairLength && towards && !sideOn) {
    const path = new Path2D();
    path.roundRect(headX - headW * 1.05, headY - headH * 0.2, headW * 2.1, headH * 0.55 + hairLength, [headW * 0.9, headW * 0.9, headW * 0.35, headW * 0.35]);
    paint(ctx, path, hairT, line, shift);
  }

  // Legs: thighs swing, knees bend on the way forward; the far leg is in shadow.
  const legT = tones(p.skirt ? p.tights : p.legs, look);
  const legFarT = tones(p.skirt ? p.tights : p.legs, look, 0.82);
  const thigh = H * 0.245;
  const shin = H * 0.25;
  const legs = [[-1, swing], [1, -swing]].map(([sign, s]) => {
    const forward = walking ? Math.max(0, Math.cos(phase) * (sign < 0 ? 1 : -1)) : 0;
    const thighAngle = s * 0.42;
    const knee = forward * 0.55 + (walking ? 0.08 : 0);
    return { sign, thighAngle, shinAngle: thighAngle - knee };
  });
  const order = sideOn ? [...legs].sort((a, b) => (a.sign * dir) - (b.sign * dir)) : legs;
  const shoeT = tones('#1d1d21', look);
  for (const leg of order) {
    const hx = x + leg.sign * hipW * 0.5 * (1 - side * 0.7);
    const far = sideOn && leg.sign * dir < 0;
    const points = limbPoints(hx, hipY, [[thigh, leg.thighAngle], [shin, leg.shinAngle]], dir, side);
    const w = H * 0.07 * build;
    paint(ctx, limbPath(points, [w, w * 0.8, w * 0.6]), far ? legFarT : legT, line, shift * 0.6);
    const [fx, fy] = points.at(-1);
    const shoe = new Path2D();
    shoe.ellipse(fx + dir * side * H * 0.022, fy + H * 0.006, H * (0.032 + side * 0.024), H * 0.019, 0, 0, Math.PI * 2);
    paint(ctx, shoe, shoeT, line, shift * 0.3);
  }

  // Arms swing opposite to the legs; the one holding an umbrella is raised.
  const coatT = tones(p.coat, look);
  const coatFarT = tones(p.coat, look, 0.82);
  const skinT = tones(p.skin, look);
  const upper = H * 0.17;
  const fore = H * 0.16;
  const armW = H * 0.05 * build;
  const arm = (sign, far) => {
    const s = sign < 0 ? -swing : swing;
    const sx = x + sign * (shoulderW - armW * 0.45) * (1 - side * 0.8);
    const sy = shoulderY + H * 0.02;
    let points;
    if (umbrellas && sign > 0) {
      // Elbow down by the side, hand up in front of the chest holding the handle.
      points = [[sx, sy], [sx + dir * side * H * 0.03, sy + upper * 0.95], [x + sign * shoulderW * 0.25 + dir * side * H * 0.07, sy + H * 0.02]];
    } else {
      points = limbPoints(sx, sy, [[upper, s * 0.38], [fore, s * 0.38 + 0.25 + Math.max(0, s) * 0.3]], dir, side);
    }
    paint(ctx, limbPath(points, [armW, armW * 0.85, armW * 0.72]), far ? coatFarT : coatT, line, shift * 0.5);
    const [hx, hy] = points.at(-1);
    const hand = new Path2D();
    hand.arc(hx, hy + H * 0.008, H * 0.021, 0, Math.PI * 2);
    paint(ctx, hand, far ? tones(p.skin, look, 0.82) : skinT, line, shift * 0.3);
  };
  if (sideOn) arm(-dir, true);

  // Backpack seen from behind, or sticking out from the side.
  if (p.backpack && (!towards || sideOn)) {
    const bx = sideOn ? x - dir * shoulderW * 0.95 : x;
    const pack = new Path2D();
    pack.roundRect(bx - H * 0.07, shoulderY + H * 0.03, H * 0.14, H * 0.2, H * 0.03);
    paint(ctx, pack, tones(p.bag ?? '#2a2d33', look), line, shift * 0.5);
  }

  // Coat / top: rounded shoulders, in at the waist, out to the hem.
  const hemY = y - H * p.hem - bob;
  const hemW = p.hem < 0.42 ? hipW * 1.14 : hipW * 1.04;
  if (p.skirt) {
    const skirt = new Path2D();
    skirt.moveTo(x - waistW, waistY + H * 0.03);
    skirt.lineTo(x + waistW, waistY + H * 0.03);
    skirt.lineTo(x + hipW * 1.5, y - H * 0.36 - bob);
    skirt.quadraticCurveTo(x, y - H * 0.345 - bob, x - hipW * 1.5, y - H * 0.36 - bob);
    skirt.closePath();
    paint(ctx, skirt, tones(p.legs, look), line, shift);
  }
  const body = new Path2D();
  body.moveTo(x - shoulderW * 0.35, neckY);
  body.quadraticCurveTo(x - shoulderW * 1.02, neckY + H * 0.004, x - shoulderW, shoulderY + H * 0.05);
  body.quadraticCurveTo(x - waistW * 1.05, waistY, x - hemW, hemY);
  body.lineTo(x + hemW, hemY);
  body.quadraticCurveTo(x + waistW * 1.05, waistY, x + shoulderW, shoulderY + H * 0.05);
  body.quadraticCurveTo(x + shoulderW * 1.02, neckY + H * 0.004, x + shoulderW * 0.35, neckY);
  body.closePath();
  paint(ctx, body, coatT, line, shift * 1.3);
  if (towards && !sideOn && H > 40) {
    // Shirt in the open collar, and where the coat closes.
    const collar = new Path2D();
    collar.moveTo(x - shoulderW * 0.32, neckY + H * 0.002);
    collar.lineTo(x + shoulderW * 0.32, neckY + H * 0.002);
    collar.lineTo(x, neckY + H * 0.085);
    collar.closePath();
    paint(ctx, collar, tones(p.coat === '#e8e4dc' || p.coat === '#ffffff' || p.coat === '#d8d2c8' ? '#3a3f4b' : '#ecebe6', look), line * 0.8, 0);
    ctx.strokeStyle = coatT.line;
    ctx.lineWidth = Math.max(0.5, line * 0.9);
    ctx.beginPath();
    ctx.moveTo(x, neckY + H * 0.085);
    ctx.lineTo(x, hemY);
    ctx.stroke();
  }

  // Shoulder bag on its strap.
  if (p.bag && !p.backpack) {
    const bagSide = towards ? 1 : -1;
    ctx.strokeStyle = tones(p.bag, look).line;
    ctx.lineWidth = Math.max(1, H * 0.009);
    ctx.beginPath();
    ctx.moveTo(x - bagSide * shoulderW * 0.5, shoulderY + H * 0.01);
    ctx.lineTo(x + bagSide * hipW * 1.15, hipY - H * 0.02);
    ctx.stroke();
    const bag = new Path2D();
    bag.roundRect(x + bagSide * hipW * 1.15 - H * 0.055, hipY - H * 0.05, H * 0.11, H * 0.09, H * 0.015);
    paint(ctx, bag, tones(p.bag, look), line, shift * 0.5);
  }

  // Near arm(s) over the body.
  if (sideOn) arm(dir, false);
  else {
    arm(-1, false);
    arm(1, false);
  }

  // Neck and head.
  const neck = new Path2D();
  neck.rect(x - H * 0.02, neckY - H * 0.035, H * 0.04, H * 0.045);
  paint(ctx, neck, tones(p.skin, look, 0.85), 0, 0);
  const faceShows = towards || sideOn;
  const head = new Path2D();
  head.ellipse(headX, headY, headW * (1 - side * 0.06), headH * 0.5, 0, 0, Math.PI * 2);
  paint(ctx, head, skinT, line, shift * 0.5);

  // Eyes, once they're near enough to make out.
  if (faceShows && H > 110) {
    ctx.fillStyle = lit('#2a2230', look);
    const eyeY = headY + headH * 0.07;
    const eyeW = headW * 0.13;
    const eyeH = headH * 0.1;
    const eyes = sideOn ? [headX + dir * headW * 0.58] : [headX - headW * 0.4, headX + headW * 0.4];
    for (const ex of eyes) {
      ctx.beginPath();
      ctx.ellipse(ex, eyeY, eyeW * (sideOn ? 0.7 : 1), eyeH, 0, 0, Math.PI * 2);
      ctx.fill();
    }
    ctx.fillStyle = 'rgb(255 255 255 / 0.85)';
    for (const ex of eyes) {
      ctx.beginPath();
      ctx.arc(ex - eyeW * 0.3, eyeY - eyeH * 0.35, eyeW * 0.32, 0, Math.PI * 2);
      ctx.fill();
    }
  }

  // Hair: the whole back of the head from behind; from the front a cap with a fringe; side
  // on, over the top and back to the nape with the fringe at the front.
  const rx = headW * 1.08;
  const ry = headH * 0.53;
  const cy = headY - headH * 0.04;
  let hair;
  if (!faceShows) {
    hair = polygon(arcPoints(headX, cy, rx, ry, 0.9 * Math.PI, 2.1 * Math.PI, 20)
      .concat([[headX + rx * 0.9, headY + headH * 0.3], [headX - rx * 0.9, headY + headH * 0.3]]));
  } else if (sideOn) {
    const points = [];
    for (let a = -0.2 * Math.PI; a >= -1.42 * Math.PI; a -= Math.PI / 18) {
      points.push([headX + Math.cos(a) * rx * dir, cy + Math.sin(a) * ry]);
    }
    points.push([headX - dir * rx * 0.35, headY + headH * 0.32]);
    points.push([headX + dir * rx * 0.05, headY - headH * 0.08]);
    points.push([headX + dir * rx * 0.62, headY - headH * 0.1]);
    hair = polygon(points);
  } else {
    // Cap over the top, then the fringe in points back across the forehead.
    const points = arcPoints(headX, cy, rx, ry, Math.PI * 0.98, Math.PI * 2.02, 18);
    const tips = 5;
    for (let i = 0; i <= tips * 2; i += 1) {
      const t = 1 - i / (tips * 2);
      points.push([headX - rx * 0.95 + rx * 1.9 * t, headY + headH * (i % 2 ? 0.0 : -0.09) + (i === 0 || i === tips * 2 ? headH * 0.12 : 0)]);
    }
    hair = polygon(points);
  }
  // Hair to the shoulders or down the back.
  if (hairLength && (!towards || sideOn)) {
    // Its own shape (painted under the cap) so the two don't cut holes in each other.
    const cx = sideOn ? headX - dir * headW * 0.45 : headX;
    const w = sideOn ? headW * 0.65 : headW * 1.02;
    const back = new Path2D();
    back.roundRect(cx - w, headY - headH * 0.1, w * 2, headH * 0.45 + hairLength, [0, 0, headW * 0.35, headW * 0.35]);
    paint(ctx, back, hairT, line, shift * 0.6);
  } else if (faceShows && !sideOn) {
    // Locks either side of the face, longer for longer hair.
    const drop = headH * (p.hairLength ? 0.42 : 0.12);
    for (const sign of [-1, 1]) {
      hair.moveTo(headX + sign * rx, cy);
      hair.lineTo(headX + sign * rx * 0.74, cy);
      hair.lineTo(headX + sign * rx * 0.8, headY + drop);
      hair.lineTo(headX + sign * rx * 1.02, headY + drop);
      hair.closePath();
    }
  }
  paint(ctx, hair, hairT, line, shift * 0.6);
  if (H > 40) {
    // The ring of shine anime hair has.
    ctx.save();
    ctx.clip(hair);
    ctx.strokeStyle = hairT.high;
    ctx.lineWidth = headH * 0.07;
    ctx.globalAlpha *= 0.7;
    ctx.beginPath();
    ctx.ellipse(headX - headW * 0.1, cy - ry * 0.25, rx * 0.72, ry * 0.5, 0, Math.PI * 1.1, Math.PI * 1.6);
    ctx.stroke();
    ctx.restore();
  }

  // A phone screen glowing in the dark.
  if (p.phone && look.night > 0.5 && towards) {
    ctx.fillStyle = `rgb(180 210 255 / ${0.7 * look.night})`;
    ctx.beginPath();
    ctx.roundRect(x - H * 0.025, shoulderY + H * 0.06, H * 0.05, H * 0.035, H * 0.005);
    ctx.fill();
  }

  if (umbrellas) drawUmbrella(ctx, x + shoulderW * 0.25 + dir * side * H * 0.07, y - H * 1.06 - bob, H, p.umbrella, look);
}

function drawUmbrella(ctx, x, y, height, kind, look) {
  const radius = height * 0.3;
  ctx.save();
  if (kind === 'clear') {
    // Clear vinyl, the Tokyo standard.
    ctx.fillStyle = `rgb(225 238 248 / ${0.28 + 0.1 * look.night})`;
    ctx.strokeStyle = `rgb(245 250 255 / 0.75)`;
  } else {
    ctx.fillStyle = lit(kind, look);
    ctx.strokeStyle = lit(kind, look, 0.8);
  }
  ctx.lineWidth = Math.max(0.6, height * 0.008);
  ctx.beginPath();
  ctx.moveTo(x - radius, y);
  ctx.quadraticCurveTo(x, y - radius * 0.75, x + radius, y);
  ctx.closePath();
  ctx.fill();
  ctx.stroke();
  // Ribs.
  ctx.beginPath();
  for (const t of [-0.5, 0, 0.5]) {
    ctx.moveTo(x, y - radius * 0.38);
    ctx.lineTo(x + t * radius, y - (t === 0 ? 0 : radius * 0.05));
  }
  ctx.stroke();
  // Shaft.
  ctx.strokeStyle = lit('#cfd6dc', look);
  ctx.beginPath();
  ctx.moveTo(x, y - radius * 0.38);
  ctx.lineTo(x, y + height * 0.26);
  ctx.stroke();
  ctx.restore();
}

// The little men on Japanese pedestrian lights, in a 1×1 lamp (x right, y down).
function standingMan(ctx, x, y, w, h) {
  const u = Math.min(w, h * 0.8);
  const cx = x + w / 2;
  const top = y + (h - u * 1.15) / 2;
  ctx.beginPath();
  ctx.arc(cx, top + u * 0.12, u * 0.11, 0, Math.PI * 2);
  ctx.fill();
  ctx.fillRect(cx - u * 0.15, top + u * 0.27, u * 0.3, u * 0.42);
  ctx.fillRect(cx - u * 0.13, top + u * 0.66, u * 0.1, u * 0.45);
  ctx.fillRect(cx + u * 0.03, top + u * 0.66, u * 0.1, u * 0.45);
}

function walkingMan(ctx, x, y, w, h) {
  const u = Math.min(w, h * 0.8);
  const cx = x + w / 2;
  const top = y + (h - u * 1.15) / 2;
  ctx.beginPath();
  ctx.arc(cx + u * 0.04, top + u * 0.12, u * 0.11, 0, Math.PI * 2);
  ctx.fill();
  ctx.lineCap = 'round';
  ctx.lineWidth = u * 0.11;
  ctx.beginPath();
  // Body leaning into the step, arms and legs apart.
  ctx.moveTo(cx + u * 0.02, top + u * 0.3);
  ctx.lineTo(cx - u * 0.04, top + u * 0.66);
  ctx.moveTo(cx - u * 0.04, top + u * 0.66);
  ctx.lineTo(cx - u * 0.24, top + u * 1.08);
  ctx.moveTo(cx - u * 0.04, top + u * 0.66);
  ctx.lineTo(cx + u * 0.12, top + u * 0.86);
  ctx.lineTo(cx + u * 0.22, top + u * 1.08);
  ctx.moveTo(cx + u * 0.01, top + u * 0.34);
  ctx.lineTo(cx - u * 0.2, top + u * 0.58);
  ctx.moveTo(cx + u * 0.01, top + u * 0.34);
  ctx.lineTo(cx + u * 0.2, top + u * 0.5);
  ctx.lineTo(cx + u * 0.25, top + u * 0.62);
  ctx.stroke();
  ctx.lineWidth = u * 0.17;
  ctx.beginPath();
  ctx.moveTo(cx + u * 0.03, top + u * 0.3);
  ctx.lineTo(cx - u * 0.03, top + u * 0.6);
  ctx.stroke();
}

/**
 * The pedestrian lights (lamp positions measured on the scene image): red standing man
 * while the cars go, green walking man for the scramble, flashing green before it ends.
 */
function drawSignals(ctx, signals, signal, view, now, night) {
  const green = signal.walk && !(signal.flashing && Math.floor(now / 500) % 2 === 0);
  const red = !signal.walk;
  for (const light of signals ?? []) {
    for (const [rect, on, colour, figure] of [
      [light.red, red, '255 64 52', standingMan],
      [light.green, green, '64 235 190', walkingMan]
    ]) {
      if (!rect || !on) continue;
      const x = view.px(rect[0]);
      const y = view.py(rect[1]);
      const w = view.px(rect[2]) - x;
      const h = view.py(rect[3]) - y;
      ctx.save();
      // Soft glow around the lamp, stronger in the dark.
      const r = Math.max(w, h) * (1.1 + night * 0.6);
      const glow = ctx.createRadialGradient(x + w / 2, y + h / 2, 0, x + w / 2, y + h / 2, r);
      glow.addColorStop(0, `rgb(${colour} / ${0.22 + night * 0.25})`);
      glow.addColorStop(1, `rgb(${colour} / 0)`);
      ctx.fillStyle = glow;
      ctx.fillRect(x + w / 2 - r, y + h / 2 - r, r * 2, r * 2);
      // The lens lit faintly, the little man bright.
      ctx.fillStyle = `rgb(${colour} / 0.16)`;
      ctx.fillRect(x, y, w, h);
      ctx.fillStyle = `rgb(${colour})`;
      ctx.strokeStyle = `rgb(${colour})`;
      ctx.shadowColor = `rgb(${colour} / 0.9)`;
      ctx.shadowBlur = Math.max(1, w * 0.12);
      figure(ctx, x, y, w, h);
      ctx.restore();
    }
  }
}

const vehicleCache = new Map();

function vehicleFor(car) {
  if (!vehicleCache.has(car.id)) {
    let roll = Math.floor(car.kindRoll * 233280);
    const random = () => {
      roll = (roll * 9301 + 49297) % 233280;
      return roll / 233280;
    };
    vehicleCache.set(car.id, makeVehicle(random));
    if (vehicleCache.size > 200) vehicleCache.delete(vehicleCache.keys().next().value);
  }
  return vehicleCache.get(car.id);
}

/**
 * Draws one frame of the crossing.
 * scene: { camera, signals }; frame: what createScramble().update() returned.
 */
export function drawScramble(ctx, scene, frame, env, view, light, now) {
  const camera = scrambleCamera(scene.camera, view);
  const { day, dusk, night } = env.periodWeights;
  const tint = [0, 1, 2].map(index => day + [1.06, 0.92, 0.84][index] * dusk + [0.8, 0.86, 1.05][index] * night);
  const rainy = ['rain', 'storm'].includes(env.weather.kind) || (env.weather.kind === 'snow' && env.weather.intensity > 0.3);
  const wet = rainy ? clamp(env.weather.intensity * 0.8, 0, 1) : 0;
  const hazeRgb = night > 0.5 ? [58, 69, 96] : dusk > 0.5 ? [230, 184, 162] : [201, 214, 230];

  // The lights are on poles at the near kerb, behind anyone waiting or walking past on
  // this side, so they go first.
  drawSignals(ctx, scene.signals, frame.signal, view, now, clamp(night + dusk * 0.5, 0, 1));

  // Far to near, people and cars together.
  const items = [
    ...frame.people.map(person => ({ z: person.z, person })),
    ...frame.cars.map(car => ({ z: car.z, car }))
  ].sort((a, b) => b.z - a.z);

  for (const item of items) {
    const z = item.z;
    if (z < 0.5) continue;
    const near = clamp((14 - z) / 12, 0, 1);
    const haze = clamp((1 - near) * (0.32 * day + 0.25 * dusk + 0.2 * night) + (env.weather.kind === 'fog' ? 0.3 * env.weather.intensity : 0), 0, 0.7);
    const look = { light: Math.max(light, 0.5), tint, haze, hazeRgb, night: clamp(night + dusk * 0.4, 0, 1) };
    if (item.person) {
      const person = item.person;
      const [x, y] = camera.project(person.x, 0, z);
      const h = 1.6 * camera.scaleAt(z);
      if (x < -h || x > view.width + h) continue;
      drawPerson(ctx, person, x, y, h, look, rainy);
    } else {
      const car = item.car;
      const vehicle = vehicleFor(car);
      const carLook = vehicleLook(env, Math.max(light, 0.55), 1.5 / z, wet, now);
      const pose = { x: car.x, z, heading: car.direction > 0 ? Math.PI / 2 : -Math.PI / 2 };
      drawVehicle3D(ctx, vehicle, pose, camera, carLook, 1.72 * vehicle.typeWidth);
    }
  }
}
