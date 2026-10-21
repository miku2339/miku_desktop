// Animated ambience drawn over the background images: weather, sky, light,
// JR trains, traffic and birds. Coordinates for scene features are given in
// the source image's normalised space (0..1) and mapped through the same
// `background-size: cover` transform the scene images use.

import { lightningFlash, normalizeWeather, sunDirection } from './environment.js';
import { drawVehicle, drawVehicleGround, spawnVehicle, vehicleAlpha, vehicleLook, vehiclePosition } from './vehicles.js';

const IMAGE_WIDTH = 1586;
const IMAGE_HEIGHT = 992;

const SCENE_FEATURES = {
  // JR Shibuya, Hachikō gates: indoors, with a glimpse of the street beyond the gates.
  shibuya: {
    size: [1679, 937],
    indoor: true,
    windows: [[0.425, 0.3, 0.49, 0.375]],
    signs: [
      { x: 0.59, y: 0.205, w: 0.24, h: 0.035, colour: '255 120 60' },
      { x: 0.865, y: 0.27, w: 0.03, h: 0.1, colour: '120 255 140' }
    ]
  },
  akihabara: {
    sky: [[0.36, 0, 0.67, 0.31]],
    ground: 0.66,
    tracks: [{ y: 0.428, height: 0.043, x0: 0.326, x1: 0.664 }],
    roads: [{
      kind: 'perspective',
      vanish: [0.5, 0.636],
      // At the reference row `refY`, each lane's centre is at `x` and a car is `carWidth` wide.
      // Japan drives on the left: the left lane heads away from us, the right lane comes towards us.
      refY: 0.78,
      carWidth: 0.125,
      wet: 0.55,
      lanes: [
        { x: 0.408, direction: 'away' },
        { x: 0.588, direction: 'toward' }
      ]
    }],
    birds: true
  },
  ikebukuro: {
    sky: [[0, 0, 1, 0.1], [0.3, 0.1, 0.9, 0.27]],
    ground: 0.7,
    birds: true
  },
  shinjuku: {
    sky: [[0, 0, 0.36, 0.3], [0.66, 0, 1, 0.33]],
    ground: 0.88,
    birds: true
  },
  hallway: {
    indoor: true,
    windows: [[0, 0, 0.23, 0.46], [0.77, 0, 1, 0.47]],
    beams: { from: 'right', floor: 0.62 }
  },
  musicroom: {
    indoor: true,
    windows: [[0, 0.02, 0.19, 0.37], [0.86, 0, 1, 0.34]],
    beams: { from: 'right', floor: 0.55 }
  }
};

const CAR_COLORS = ['#f4f5f7', '#1d1f24', '#c4c9cf', '#2b3a67', '#b3202a', '#e7e2d4', '#30343b', '#f2c230', '#5b7c99'];

function seeded(seed) {
  let value = seed % 2147483647;
  if (value <= 0) value += 2147483646;
  return () => {
    value = (value * 16807) % 2147483647;
    return (value - 1) / 2147483646;
  };
}

function shade(hex, factor, tint = [1, 1, 1]) {
  const value = parseInt(hex.slice(1), 16);
  const channels = [(value >> 16) & 255, (value >> 8) & 255, value & 255];
  const [r, g, b] = channels.map((channel, index) => Math.round(Math.min(255, channel * factor * tint[index])));
  return `rgb(${r} ${g} ${b})`;
}

export function createAmbient(canvas) {
  const context = canvas.getContext('2d');
  let width = 1;
  let height = 1;
  let cover = { scale: 1, x: 0, y: 0, width: IMAGE_WIDTH, height: IMAGE_HEIGHT };
  let enabled = true;
  let lastNow = null;
  let drops = [];
  let flakes = [];
  let splashes = [];
  let motes = [];
  const sceneState = new Map();
  const stars = new Map();
  let activeLevel = 0;
  let pixelRatio = 1;
  // Scratch canvases: each vehicle is painted once per frame, then stamped onto the
  // scene and again, flipped and fading, as its reflection in the wet road.
  const sprite = document.createElement('canvas');
  const spriteContext = sprite.getContext('2d');
  const mirror = document.createElement('canvas');
  const mirrorContext = mirror.getContext('2d');

  function resize() {
    width = Math.max(1, window.innerWidth);
    height = Math.max(1, window.innerHeight);
    const ratio = Math.min(window.devicePixelRatio || 1, 1.5);
    pixelRatio = ratio;
    canvas.width = Math.round(width * ratio);
    canvas.height = Math.round(height * ratio);
    context.setTransform(ratio, 0, 0, ratio, 0, 0);
    useImage([IMAGE_WIDTH, IMAGE_HEIGHT]);
  }

  /** Point the coordinate helpers at a scene image (scenes may differ in size). */
  function useImage([imageWidth, imageHeight]) {
    const scale = Math.max(width / imageWidth, height / imageHeight);
    cover = {
      scale,
      width: imageWidth,
      height: imageHeight,
      x: (width - imageWidth * scale) / 2,
      y: (height - imageHeight * scale) / 2
    };
  }

  const px = nx => cover.x + nx * cover.width * cover.scale;
  const py = ny => cover.y + ny * cover.height * cover.scale;
  const size = n => n * cover.height * cover.scale;

  function stateFor(id) {
    if (!sceneState.has(id)) {
      sceneState.set(id, { trains: [], cars: [], birds: null, nextTrain: null, nextCar: null, nextBirds: null });
    }
    return sceneState.get(id);
  }

  function starsFor(id, features) {
    if (stars.has(id)) return stars.get(id);
    const random = seeded(id.split('').reduce((sum, char) => sum + char.charCodeAt(0) * 31, 7));
    const list = [];
    for (const [x0, y0, x1, y1] of features.sky || []) {
      const count = Math.round((x1 - x0) * (y1 - y0) * 420);
      for (let i = 0; i < count; i += 1) {
        list.push({
          x: x0 + random() * (x1 - x0),
          y: y0 + random() * (y1 - y0),
          r: 0.4 + random() * 1.1,
          phase: random() * Math.PI * 2,
          speed: 0.6 + random() * 1.8
        });
      }
    }
    stars.set(id, list);
    return list;
  }

  // ---- light & sky -----------------------------------------------------

  function drawSkyCloud(features, weather, alpha) {
    if (features.indoor || weather.cloud < 0.3) return;
    const amount = Math.min(1, (weather.cloud - 0.3) / 0.7) * (weather.kind === 'clear' ? 0.3 : 1);
    if (amount <= 0) return;
    const dark = weather.kind === 'storm' ? 0.42 : weather.kind === 'rain' ? 0.58 : weather.kind === 'snow' ? 0.86 : 0.74;
    const grey = Math.round(255 * dark);
    const colour = `${grey} ${grey + 4} ${grey + 12}`;
    // Soft overcast over the upper part of the picture, fading out towards the street.
    const gradient = context.createLinearGradient(0, 0, 0, height * 0.62);
    gradient.addColorStop(0, `rgb(${colour} / ${0.5 * amount * alpha})`);
    gradient.addColorStop(0.55, `rgb(${colour} / ${0.22 * amount * alpha})`);
    gradient.addColorStop(1, `rgb(${colour} / 0)`);
    context.fillStyle = gradient;
    context.fillRect(0, 0, width, height * 0.62);
  }


  function drawStars(id, features, env, alpha, now) {
    const visibility = env.periodWeights.night * (1 - env.weather.cloud) * alpha;
    if (visibility < 0.02) return;
    for (const star of starsFor(id, features)) {
      const twinkle = 0.55 + 0.45 * Math.sin(now / 1000 * star.speed + star.phase);
      context.fillStyle = `rgb(235 245 255 / ${visibility * twinkle * 0.9})`;
      context.beginPath();
      context.arc(px(star.x), py(star.y), star.r, 0, Math.PI * 2);
      context.fill();
    }
  }

  function drawSunGlow(features, env, alpha) {
    if (features.indoor) return;
    const { day, dusk } = env.periodWeights;
    const strength = (day * 0.16 + dusk * 0.3) * (1 - env.weather.cloud * 0.85) * alpha;
    if (strength < 0.01) return;
    const sun = sunDirection(env.hour, env.sunrise, env.sunset);
    const x = width * (0.5 + sun.x / 48);
    const y = height * (0.02 + (24 - sun.y) / 60);
    const radius = Math.max(width, height) * (0.45 + dusk * 0.25);
    const gradient = context.createRadialGradient(x, y, 0, x, y, radius);
    const warm = dusk > day ? '255 168 110' : '255 244 214';
    gradient.addColorStop(0, `rgb(${warm} / ${strength})`);
    gradient.addColorStop(0.4, `rgb(${warm} / ${strength * 0.35})`);
    gradient.addColorStop(1, `rgb(${warm} / 0)`);
    context.globalCompositeOperation = 'screen';
    context.fillStyle = gradient;
    context.fillRect(0, 0, width, height);
    context.globalCompositeOperation = 'source-over';
  }

  /** Departure boards and signs glow softly, like lit panels. */
  function drawSigns(features, now) {
    context.globalCompositeOperation = 'screen';
    for (const [index, sign] of features.signs.entries()) {
      const pulse = 0.55 + 0.45 * Math.sin(now / 900 + index * 1.7);
      const cx = px(sign.x + sign.w / 2);
      const cy = py(sign.y + sign.h / 2);
      const radius = size(Math.max(sign.w, sign.h)) * 0.8;
      const glow = context.createRadialGradient(cx, cy, 0, cx, cy, radius);
      glow.addColorStop(0, `rgb(${sign.colour} / ${0.16 * pulse})`);
      glow.addColorStop(1, `rgb(${sign.colour} / 0)`);
      context.fillStyle = glow;
      context.fillRect(cx - radius, cy - radius, radius * 2, radius * 2);
    }
    context.globalCompositeOperation = 'source-over';
  }

  function drawWindowBeams(features, env, alpha, now) {
    if (!features.beams) return;
    const { day, dusk } = env.periodWeights;
    const sunny = (day + dusk * 0.8) * (1 - env.weather.cloud * 0.9) * alpha;
    if (sunny < 0.02) return;
    const sway = Math.sin(now / 9000) * 0.015;
    const warm = dusk > day ? '255 190 140' : '255 248 228';
    context.globalCompositeOperation = 'screen';
    for (const [x0, y0, x1, y1] of features.windows) {
      const fromRight = x0 > 0.5;
      const floorY = features.beams.floor;
      const shift = fromRight ? -0.28 : 0.28;
      context.beginPath();
      context.moveTo(px(x0), py(y0));
      context.lineTo(px(x1), py(y0));
      context.lineTo(px(x1 + shift + sway), py(floorY + 0.25));
      context.lineTo(px(x0 + shift + sway), py(floorY + 0.25));
      context.closePath();
      const gradient = context.createLinearGradient(px(x0), py(y0), px(x0 + shift), py(floorY + 0.25));
      gradient.addColorStop(0, `rgb(${warm} / ${0.16 * sunny})`);
      gradient.addColorStop(1, `rgb(${warm} / 0)`);
      context.fillStyle = gradient;
      context.fill();
    }
    context.globalCompositeOperation = 'source-over';

    // Dust motes drifting in the light.
    if (motes.length === 0) {
      const random = seeded(4242);
      motes = Array.from({ length: 46 }, () => ({ x: random(), y: random() * 0.75, phase: random() * 10, speed: 0.3 + random() }));
    }
    for (const mote of motes) {
      const t = now / 1000 * mote.speed * 0.05 + mote.phase;
      const x = (mote.x + Math.sin(t) * 0.02 + t * 0.004) % 1;
      const y = mote.y + Math.cos(t * 1.3) * 0.02;
      const glow = (0.5 + 0.5 * Math.sin(t * 3)) * sunny * 0.55;
      context.fillStyle = `rgb(255 250 235 / ${glow})`;
      context.beginPath();
      context.arc(px(x), py(y), 1.3, 0, Math.PI * 2);
      context.fill();
    }
  }

  // ---- vehicles ---------------------------------------------------------

  function lightLevel(env) {
    const { day, dusk, night } = env.periodWeights;
    const base = day + dusk * 0.78 + night * 0.38;
    const weather = env.weather.kind === 'storm' ? 0.75 : env.weather.kind === 'rain' ? 0.82 : env.weather.kind === 'cloudy' ? 0.9 : 1;
    return base * (1 - (1 - weather) * env.weather.intensity);
  }

  function drawTrain(train, track, env, now) {
    const h = size(track.height);
    const carLength = h * 5.4;
    const gap = h * 0.08;
    const totalLength = train.cars * (carLength + gap);
    const progress = (now - train.start) / train.duration;
    const visibleLeft = px(track.x0);
    const visibleRight = px(track.x1);
    const travel = visibleRight - visibleLeft + totalLength;
    const head = train.direction > 0
      ? visibleLeft - totalLength + progress * travel
      : visibleRight - progress * travel;
    const top = py(track.y) - h;
    const light = lightLevel(env);
    const night = env.periodWeights.night;

    context.save();
    context.beginPath();
    context.rect(visibleLeft, top - h, visibleRight - visibleLeft, h * 2.2);
    context.clip();
    for (let index = 0; index < train.cars; index += 1) {
      const x = head + index * (carLength + gap);
      if (x > visibleRight || x + carLength < visibleLeft) continue;
      // Stainless body with a slightly darker skirt.
      const body = context.createLinearGradient(0, top, 0, top + h);
      body.addColorStop(0, shade('#e3e8ec', light));
      body.addColorStop(0.75, shade('#c9d0d6', light));
      body.addColorStop(1, shade('#9ea6ad', light));
      context.fillStyle = body;
      context.beginPath();
      context.roundRect(x, top, carLength, h * 0.9, h * 0.1);
      context.fill();
      // Yamanote green line along the top.
      context.fillStyle = shade('#80c241', light);
      context.fillRect(x + h * 0.06, top + h * 0.06, carLength - h * 0.12, h * 0.07);
      // Continuous black window band, lit warm at night.
      const windowTop = top + h * 0.2;
      const windowHeight = h * 0.3;
      context.fillStyle = shade('#1e252c', light + 0.15);
      context.fillRect(x + h * 0.08, windowTop, carLength - h * 0.16, windowHeight);
      if (night > 0.15) {
        context.fillStyle = `rgb(255 239 200 / ${0.35 + night * 0.55})`;
        context.shadowColor = 'rgb(255 232 180 / 0.9)';
        context.shadowBlur = h * 0.45 * night;
        for (let pane = 0; pane < 5; pane += 1) {
          const paneX = x + carLength * (0.06 + pane * 0.19);
          context.fillRect(paneX, windowTop + h * 0.03, carLength * 0.13, windowHeight - h * 0.06);
        }
        context.shadowBlur = 0;
      }
      // Doors: green-framed, between the window panes.
      for (let door = 0; door < 4; door += 1) {
        const doorX = x + carLength * (0.185 + door * 0.19);
        context.fillStyle = shade('#80c241', light);
        context.fillRect(doorX, top + h * 0.16, h * 0.34, h * 0.68);
        context.fillStyle = night > 0.15 ? `rgb(255 239 200 / ${0.3 + night * 0.5})` : shade('#2a333b', light);
        context.fillRect(doorX + h * 0.06, top + h * 0.22, h * 0.22, h * 0.26);
        context.fillStyle = shade('#d5dbe0', light);
        context.fillRect(doorX + h * 0.06, top + h * 0.5, h * 0.22, h * 0.3);
      }
      // Bogies and pantograph hint.
      context.fillStyle = shade('#2a2d31', light);
      context.fillRect(x + carLength * 0.1, top + h * 0.88, carLength * 0.16, h * 0.12);
      context.fillRect(x + carLength * 0.74, top + h * 0.88, carLength * 0.16, h * 0.12);
      if (index % 3 === 1) {
        context.strokeStyle = shade('#3a3f45', light);
        context.lineWidth = Math.max(1, h * 0.04);
        context.beginPath();
        context.moveTo(x + carLength * 0.4, top);
        context.lineTo(x + carLength * 0.47, top - h * 0.28);
        context.lineTo(x + carLength * 0.54, top);
        context.stroke();
      }
    }
    // Headlight on the leading car at dusk / night.
    const lightOn = env.periodWeights.night + env.periodWeights.dusk * 0.6 + env.weather.intensity * 0.4;
    if (lightOn > 0.2) {
      const frontX = train.direction > 0 ? head + totalLength - gap : head;
      const glow = context.createRadialGradient(frontX, top + h * 0.7, 0, frontX, top + h * 0.7, h * 1.6);
      glow.addColorStop(0, `rgb(255 250 225 / ${Math.min(0.9, lightOn)})`);
      glow.addColorStop(1, 'rgb(255 250 225 / 0)');
      context.fillStyle = glow;
      context.fillRect(frontX - h * 1.6, top - h, h * 3.2, h * 3.2);
    }
    context.restore();
  }

  function drawSideCar(car, road, env, now) {
    const h = size(road.height);
    const length = h * 2.4;
    const progress = (now - car.start) / car.duration;
    const left = px(road.x0);
    const right = px(road.x1);
    const travel = right - left + length * 2;
    const x = car.direction > 0 ? left - length + progress * travel : right + length - progress * travel - length;
    const bottom = py(road.y) + car.lane * h * 0.25;
    const light = lightLevel(env);
    const night = env.periodWeights.night + env.periodWeights.dusk * 0.5;

    context.save();
    context.beginPath();
    context.rect(left, bottom - h * 3, right - left, h * 4);
    context.clip();
    context.fillStyle = shade(car.color, light);
    context.beginPath();
    context.roundRect(x, bottom - h * 0.55, length, h * 0.42, h * 0.12);
    context.fill();
    context.beginPath();
    context.roundRect(x + length * 0.2, bottom - h * 0.92, length * 0.55, h * 0.42, h * 0.14);
    context.fill();
    context.fillStyle = night > 0.3 ? 'rgb(60 70 85 / 0.9)' : shade('#33414d', light);
    context.fillRect(x + length * 0.26, bottom - h * 0.84, length * 0.2, h * 0.28);
    context.fillRect(x + length * 0.5, bottom - h * 0.84, length * 0.2, h * 0.28);
    context.fillStyle = shade('#16181b', light);
    for (const wheel of [0.22, 0.78]) {
      context.beginPath();
      context.arc(x + length * wheel, bottom - h * 0.12, h * 0.13, 0, Math.PI * 2);
      context.fill();
    }
    if (night > 0.25) {
      const frontX = car.direction > 0 ? x + length : x;
      const backX = car.direction > 0 ? x : x + length;
      const beam = context.createRadialGradient(frontX, bottom - h * 0.35, 0, frontX, bottom - h * 0.35, h * 1.3);
      beam.addColorStop(0, `rgb(255 246 214 / ${0.85 * night})`);
      beam.addColorStop(1, 'rgb(255 246 214 / 0)');
      context.fillStyle = beam;
      context.fillRect(frontX - h * 1.3, bottom - h * 1.6, h * 2.6, h * 2.6);
      context.fillStyle = `rgb(255 40 50 / ${0.9 * night})`;
      context.fillRect(backX - h * 0.06, bottom - h * 0.48, h * 0.12, h * 0.1);
    }
    context.restore();
  }

  function fitScratch(target, cssWidth, cssHeight) {
    const w = Math.ceil(cssWidth * pixelRatio);
    const h = Math.ceil(cssHeight * pixelRatio);
    if (target.width < w || target.height < h) {
      target.width = Math.max(target.width, w);
      target.height = Math.max(target.height, h);
    }
    return [w, h];
  }

  function drawPerspectiveCar(car, road, env, now, sceneAlpha) {
    const { z, scale } = vehiclePosition(car, now);
    const fade = vehicleAlpha(z);
    const lane = road.lanes[car.lane];
    const cx = px(road.vanish[0] + (lane.x - road.vanish[0]) * scale);
    const ground = py(road.vanish[1] + (road.refY - road.vanish[1]) * scale);
    const w = size(road.carWidth) * scale * (car.typeWidth ?? 1);
    if (fade <= 0.01 || w < 2) return;
    const wet = Math.min(1, road.wet + (['rain', 'storm'].includes(env.weather.kind) ? env.weather.intensity * 0.6 : 0)
      + (env.weather.kind === 'snow' ? -0.3 : 0));
    const look = vehicleLook(env, lightLevel(env), scale, Math.max(0, wet), now);

    const above = w * 1.5;
    const below = w * 0.06;
    const spanX = w * 0.78;
    const [spriteW, spriteH] = fitScratch(sprite, spanX * 2, above + below);
    spriteContext.setTransform(1, 0, 0, 1, 0, 0);
    spriteContext.clearRect(0, 0, spriteW, spriteH);
    spriteContext.setTransform(pixelRatio, 0, 0, pixelRatio, 0, 0);
    drawVehicle(spriteContext, car, spanX, above, w, look);

    context.save();
    context.globalAlpha = sceneAlpha * fade;
    drawVehicleGround(context, car, cx, ground, w, look);
    if (look.wet > 0.05) {
      // Reflection: the sprite flipped about the road line, fading out with distance.
      fitScratch(mirror, spanX * 2, above + below);
      mirrorContext.setTransform(1, 0, 0, 1, 0, 0);
      mirrorContext.globalCompositeOperation = 'source-over';
      mirrorContext.clearRect(0, 0, spriteW, spriteH);
      mirrorContext.setTransform(1, 0, 0, -1, 0, spriteH);
      mirrorContext.drawImage(sprite, 0, 0, spriteW, spriteH, 0, 0, spriteW, spriteH);
      mirrorContext.setTransform(1, 0, 0, 1, 0, 0);
      mirrorContext.globalCompositeOperation = 'destination-in';
      const groundRow = below * pixelRatio;
      const mask = mirrorContext.createLinearGradient(0, groundRow, 0, groundRow + w * 0.7 * pixelRatio);
      mask.addColorStop(0, 'rgb(0 0 0 / 1)');
      mask.addColorStop(1, 'rgb(0 0 0 / 0)');
      mirrorContext.fillStyle = mask;
      mirrorContext.fillRect(0, 0, spriteW, spriteH);
      mirrorContext.globalCompositeOperation = 'source-over';
      context.globalAlpha = sceneAlpha * fade * 0.32 * look.wet;
      context.drawImage(mirror, 0, 0, spriteW, spriteH, cx - spanX, ground - below, spanX * 2, above + below);
      context.globalAlpha = sceneAlpha * fade;
    }
    // A hint of softness so the vector shapes sit in the painted scene (more with distance).
    context.filter = `blur(${(0.25 + look.haze * 0.9).toFixed(2)}px)`;
    context.drawImage(sprite, 0, 0, spriteW, spriteH, cx - spanX, ground - above, spanX * 2, above + below);
    context.filter = 'none';
    context.restore();
  }

  function drawBirds(flock, features, env, now) {
    const progress = (now - flock.start) / flock.duration;
    if (progress > 1) return false;
    const [x0, y0, x1, y1] = features.sky[0];
    const light = lightLevel(env) * 0.55;
    context.strokeStyle = shade('#2a2f36', light + 0.2);
    context.lineWidth = 1.4;
    for (const bird of flock.birds) {
      const nx = flock.direction > 0
        ? x0 - 0.1 + progress * (x1 - x0 + 0.2) + bird.dx
        : x1 + 0.1 - progress * (x1 - x0 + 0.2) + bird.dx;
      const ny = y0 + (y1 - y0) * flock.altitude + bird.dy + Math.sin(progress * 6 + bird.dx * 20) * 0.006;
      const flap = Math.sin(now / 120 + bird.phase) * 0.6;
      const span = size(0.009) * bird.scale;
      const x = px(nx);
      const y = py(ny);
      context.beginPath();
      context.moveTo(x - span, y - span * flap * 0.6);
      context.quadraticCurveTo(x - span * 0.4, y - span * 0.2, x, y);
      context.quadraticCurveTo(x + span * 0.4, y - span * 0.2, x + span, y - span * flap * 0.6);
      context.stroke();
    }
    return true;
  }

  function scheduleScene(id, features, env, now, alpha) {
    const s = stateFor(id);
    const random = Math.random;
    if (features.tracks) {
      if (s.nextTrain === null) s.nextTrain = now + 6000 + random() * 14000;
      if (now >= s.nextTrain) {
        const track = Math.floor(random() * features.tracks.length);
        s.trains.push({ track, start: now, duration: 8500 + random() * 3000, direction: random() < 0.5 ? 1 : -1, cars: 11 });
        s.nextTrain = now + 40000 + random() * 80000;
      }
      s.trains = s.trains.filter(train => now - train.start < train.duration);
      for (const train of s.trains) drawTrain(train, features.tracks[train.track], env, now);
    }
    for (const road of features.roads || []) {
      if (road.kind === 'side') {
        if (s.nextCar === null) s.nextCar = now + 1500 + random() * 4000;
        if (now >= s.nextCar) {
          const color = CAR_COLORS[Math.floor(random() * CAR_COLORS.length)];
          const direction = random() < 0.5 ? 1 : -1;
          s.cars.push({ road, start: now, duration: 4200 + random() * 2200, direction, lane: direction > 0 ? 0 : 1, color });
          s.nextCar = now + 3500 + random() * 8000;
        }
        continue;
      }
      // Each lane has its own rhythm: sometimes a little queue, sometimes an empty road.
      s.laneTimers ??= road.lanes.map(() => now + 800 + random() * 5000);
      road.lanes.forEach((lane, index) => {
        if (now < s.laneTimers[index]) return;
        const ahead = s.cars.filter(car => car.road === road && car.lane === index).at(-1) ?? null;
        const vehicle = spawnVehicle({ ...lane, index }, now, random, ahead);
        if (vehicle) {
          vehicle.road = road;
          s.cars.push(vehicle);
          s.laneTimers[index] = now + (random() < 0.3 ? 1500 + random() * 2000 : 4500 + random() * 9000);
        } else s.laneTimers[index] = now + 700;
      });
    }
    s.cars = s.cars.filter(car => (car.road.kind === 'side'
      ? now - car.start < car.duration
      : !vehiclePosition(car, now).done));
    // Far vehicles first so near ones overlap them.
    const depth = car => (car.road.kind === 'side' ? 0 : vehiclePosition(car, now).z);
    const sorted = [...s.cars].sort((a, b) => depth(b) - depth(a));
    for (const car of sorted) {
      if (car.road.kind === 'side') drawSideCar(car, car.road, env, now);
      else drawPerspectiveCar(car, car.road, env, now, alpha);
    }
    if (features.birds && features.sky && env.periodWeights.night < 0.6 && ['clear', 'cloudy'].includes(env.weather.kind)) {
      if (s.nextBirds === null) s.nextBirds = now + 15000 + random() * 30000;
      if (!s.birds && now >= s.nextBirds) {
        const count = 3 + Math.floor(random() * 4);
        s.birds = {
          start: now,
          duration: 14000 + random() * 8000,
          direction: random() < 0.5 ? 1 : -1,
          altitude: 0.25 + random() * 0.5,
          birds: Array.from({ length: count }, (_, index) => ({
            dx: index * 0.018 + random() * 0.01,
            dy: Math.abs(index - count / 2) * 0.012 + random() * 0.006,
            phase: random() * 6,
            scale: 0.8 + random() * 0.5
          }))
        };
        s.nextBirds = now + 45000 + random() * 75000;
      }
      if (s.birds && !drawBirds(s.birds, features, env, now)) s.birds = null;
    }
    return s.trains.length > 0 || s.cars.length > 0 || Boolean(s.birds);
  }

  // ---- weather particles ---------------------------------------------------

  function drawPrecipitation(env, delta, indoorAlpha, outdoorAlpha, windowsList) {
    const { kind, intensity, wind } = env.weather;
    const raining = kind === 'rain' || kind === 'storm';
    const snowing = kind === 'snow';
    if (!raining) drops = [];
    if (!snowing) flakes = [];
    if (!raining && !snowing) return false;

    const area = width * height / (1440 * 900);
    if (raining) {
      const target = Math.round((90 + 260 * intensity) * area);
      while (drops.length < target) {
        drops.push({ x: Math.random() * width * 1.2 - width * 0.1, y: Math.random() * -height, speed: 1000 + Math.random() * 800, length: 18 + Math.random() * 26 });
      }
      drops.length = Math.min(drops.length, target);
    } else {
      const target = Math.round((60 + 180 * intensity) * area);
      while (flakes.length < target) {
        flakes.push({ x: Math.random() * width, y: Math.random() * -height, speed: 35 + Math.random() * 55, r: 1 + Math.random() * 2.4, phase: Math.random() * 6 });
      }
      flakes.length = Math.min(flakes.length, target);
    }

    const drawLayer = (alpha) => {
      if (alpha <= 0.01) return;
      if (raining) {
        const slant = wind * 0.35;
        context.strokeStyle = `rgb(215 228 245 / ${(0.3 + intensity * 0.3) * alpha})`;
        context.lineWidth = 1.3;
        context.beginPath();
        for (const drop of drops) {
          context.moveTo(drop.x, drop.y);
          context.lineTo(drop.x + drop.length * slant, drop.y + drop.length);
        }
        context.stroke();
      } else {
        context.fillStyle = `rgb(255 255 255 / ${0.75 * alpha})`;
        for (const flake of flakes) {
          context.beginPath();
          context.arc(flake.x, flake.y, flake.r, 0, Math.PI * 2);
          context.fill();
        }
      }
    };

    // Advance particles once per frame.
    for (const drop of drops) {
      drop.y += drop.speed * delta;
      drop.x += drop.speed * delta * wind * 0.35;
      if (drop.y > height) {
        if (outdoorAlpha > 0.05 && Math.random() < 0.25) splashes.push({ x: drop.x, y: height * (0.78 + Math.random() * 0.22), age: 0 });
        drop.y = -drop.length - Math.random() * 60;
        drop.x = Math.random() * width * 1.2 - width * 0.1;
      }
    }
    for (const flake of flakes) {
      flake.y += flake.speed * delta;
      flake.x += Math.sin(flake.y / 40 + flake.phase) * 0.4 + wind * 25 * delta;
      if (flake.y > height) {
        flake.y = -5;
        flake.x = Math.random() * width;
      }
    }

    drawLayer(outdoorAlpha);
    if (indoorAlpha > 0.01 && windowsList.length) {
      context.save();
      context.beginPath();
      for (const [x0, y0, x1, y1] of windowsList) context.rect(x0 * width, y0 * height, (x1 - x0) * width, (y1 - y0) * height);
      context.clip();
      drawLayer(indoorAlpha);
      context.restore();
    }

    // Ripples on the ground.
    splashes = splashes.filter(splash => (splash.age += delta) < 0.35);
    if (outdoorAlpha > 0.05) {
      context.strokeStyle = `rgb(220 232 245 / ${0.35 * outdoorAlpha})`;
      for (const splash of splashes) {
        const radius = 2 + splash.age * 22;
        context.globalAlpha = 1 - splash.age / 0.35;
        context.beginPath();
        context.ellipse(splash.x, splash.y, radius, radius * 0.3, 0, 0, Math.PI * 2);
        context.stroke();
      }
      context.globalAlpha = 1;
    }
    return true;
  }

  function drawAtmosphere(env, outdoorAlpha, indoorAlpha, now) {
    const { kind, intensity } = env.weather;
    const total = outdoorAlpha + indoorAlpha * 0.4;
    // Overall weather tint.
    const tints = {
      cloudy: [120, 130, 145, 0.12],
      fog: [215, 222, 230, 0.16],
      rain: [55, 70, 95, 0.2],
      storm: [30, 38, 60, 0.32],
      snow: [225, 232, 245, 0.12]
    };
    const tint = tints[kind];
    if (kind !== 'clear' && intensity > 0) {
      context.globalCompositeOperation = 'saturation';
      context.fillStyle = `rgb(128 128 128 / ${Math.min(0.6, 0.5 * intensity * env.weather.cloud) * total})`;
      context.fillRect(0, 0, width, height);
      context.globalCompositeOperation = 'source-over';
    }
    if (tint && intensity > 0) {
      context.fillStyle = `rgb(${tint[0]} ${tint[1]} ${tint[2]} / ${tint[3] * intensity * total})`;
      context.fillRect(0, 0, width, height);
    }
    // Fog bank around the horizon.
    if (kind === 'fog' && outdoorAlpha > 0) {
      const drift = Math.sin(now / 7000) * 0.04;
      const gradient = context.createLinearGradient(0, height * 0.25, 0, height);
      gradient.addColorStop(0, 'rgb(235 240 245 / 0)');
      gradient.addColorStop(0.45 + drift, `rgb(235 240 245 / ${0.55 * intensity * outdoorAlpha})`);
      gradient.addColorStop(1, `rgb(235 240 245 / ${0.25 * intensity * outdoorAlpha})`);
      context.fillStyle = gradient;
      context.fillRect(0, 0, width, height);
    }
    // Lightning.
    const flash = lightningFlash(Date.now(), env.weather);
    if (flash > 0) {
      context.fillStyle = `rgb(235 240 255 / ${flash * (0.5 * outdoorAlpha + 0.25 * indoorAlpha)})`;
      context.fillRect(0, 0, width, height);
    }
    return kind === 'fog' || flash > 0 || kind === 'storm';
  }

  // ---- frame -----------------------------------------------------------------

  function update(now, env) {
    const delta = lastNow === null ? 0 : Math.min(0.1, (now - lastNow) / 1000);
    lastNow = now;
    context.clearRect(0, 0, width, height);
    if (!enabled) {
      activeLevel = 0;
      return;
    }
    const weather = normalizeWeather(env.weather);
    const environment = { ...env, weather };
    let animating = false;
    let gentle = false;
    let outdoorAlpha = 0;
    let indoorAlpha = 0;
    const windowsList = [];

    for (const [id, alpha] of Object.entries(env.sceneWeights || {})) {
      if (alpha < 0.01) continue;
      const features = SCENE_FEATURES[id];
      if (!features) continue;
      useImage(features.size || [IMAGE_WIDTH, IMAGE_HEIGHT]);
      context.globalAlpha = alpha;
      if (features.signs) {
        drawSigns(features, now);
        gentle = true;
      }
      if (features.indoor) {
        indoorAlpha += alpha;
        windowsList.push(...features.windows.map(rect => rect.map((value, index) => (
          index % 2 === 0 ? px(value) / width : py(value) / height
        ))));
        drawWindowBeams(features, environment, 1, now);
        gentle = true;
      } else {
        outdoorAlpha += alpha;
        drawSkyCloud(features, weather, 1);
        drawStars(id, features, environment, 1, now);
        drawSunGlow(features, environment, 1);
        if (scheduleScene(id, features, environment, now, alpha)) animating = true;
        if (environment.periodWeights.night > 0.05) gentle = true;
      }
      context.globalAlpha = 1;
    }

    if (drawPrecipitation(environment, delta, indoorAlpha, outdoorAlpha, windowsList)) animating = true;
    if (drawAtmosphere(environment, outdoorAlpha, indoorAlpha, now)) animating = true;
    activeLevel = animating ? 2 : gentle ? 1 : 0;
  }

  return {
    resize,
    update,
    setEnabled(value) {
      enabled = Boolean(value);
      if (!enabled) context.clearRect(0, 0, width, height);
    },
    get enabled() {
      return enabled;
    },
    /** Frame interval the ambience currently needs (ms). */
    desiredInterval() {
      if (!enabled) return 1000;
      if (activeLevel === 2) return 1000 / 24;
      return activeLevel === 1 ? 1000 / 10 : 1000;
    }
  };
}
