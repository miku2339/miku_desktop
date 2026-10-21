import test from 'node:test';
import assert from 'node:assert/strict';
import { buildPaths, createTraffic, desiredSpeed, drawVehicle3D, pointOnPath, rowDepth, VEHICLE_TYPES } from '../Wallpaper/companion/vehicles.js';
import { mulberry32 } from '../Wallpaper/companion/variety.js';

// The GiGO corner, as configured in ambient.js.
const CROSS = {
  kind: 'cross3d',
  vanish: [0.5, 0.612],
  refY: 0.69,
  carWidth: 0.078 * 1.13,
  focal: 0.85,
  aspect: 1.6,
  lanes: [
    { y: 0.692, direction: 'left' },
    { y: 0.68, direction: 'left' },
    { y: 0.667, direction: 'right' },
    { y: 0.655, direction: 'right' }
  ]
};

// A road running away from the camera, with the junction turn-off.
const STREET = {
  kind: 'street3d',
  vanish: [0.5, 0.636],
  refY: 0.78,
  carWidth: 0.125,
  focal: 1.1,
  aspect: 1.6,
  lanes: [{ x: 0.408, direction: 'away' }, { x: 0.588, direction: 'toward' }],
  junction: 2.7,
  far: 15,
  turnRadius: 0.2,
  crossOffset: 0.14,
  hideX: 0.44
};

const MIKU_FOOT_Y = 0.915;

const drawingContext = () => ({
  globalAlpha: 1,
  beginPath() {},
  moveTo() {},
  lineTo() {},
  closePath() {},
  fill() {},
  stroke() {},
  save() {},
  restore() {},
  clip() {},
  fillRect() {},
  translate() {},
  scale() {},
  createLinearGradient: () => ({ addColorStop() {} }),
  createRadialGradient: () => ({ addColorStop() {} })
});

test('cross traffic: near lanes run right→left, far lanes left→right, each fully across the picture', () => {
  const paths = buildPaths(CROSS);
  assert.equal(Object.keys(paths).length, 4);
  CROSS.lanes.forEach((lane, index) => {
    const path = paths[`lane${index}`];
    const start = pointOnPath(path, 0);
    const end = pointOnPath(path, path.length);
    const z = rowDepth(CROSS, lane.y);
    const halfScreen = 0.5 * CROSS.aspect * z;
    if (lane.direction === 'left') {
      assert.ok(start.x > halfScreen && end.x < -halfScreen);
      assert.ok(Math.abs(start.heading + Math.PI / 2) < 1e-9);
    } else {
      assert.ok(start.x < -halfScreen && end.x > halfScreen);
      assert.ok(Math.abs(start.heading - Math.PI / 2) < 1e-9);
    }
  });
});

test('traffic never comes as close to the camera as where Miku stands', () => {
  for (const road of [CROSS, STREET]) {
    const mikuDepth = rowDepth(road, MIKU_FOOT_Y) * road.focal;
    for (const path of Object.values(buildPaths(road))) {
      for (let d = 0; d <= path.length; d += path.length / 400) {
        const nearestCorner = pointOnPath(path, d).z - road.carWidth * 1.3 * 4.6 / 2;
        assert.ok(nearestCorner > mikuDepth * 1.5, `${road.kind}: ${nearestCorner} vs Miku at ${mikuDepth}`);
      }
    }
  }
});

test('oncoming street traffic turns off at the junction and slows down for the corner', () => {
  const { toward, away } = buildPaths(STREET);
  const arc = toward.parts.find(part => part.type === 'arc');
  assert.ok(desiredSpeed(toward, arc.offset + arc.length / 2) < desiredSpeed(toward, 0));
  assert.ok(Math.abs(pointOnPath(toward, 0).heading - Math.PI) < 1e-9);
  assert.ok(Math.abs(pointOnPath(toward, toward.length).heading - Math.PI / 2) < 1e-9);
  assert.ok(Math.abs(pointOnPath(away, away.length).heading) < 1e-9);
});

test('vehicles keep their distance and never drive through each other', () => {
  for (const road of [CROSS, STREET]) {
    const traffic = createTraffic(road, mulberry32(road.kind.length * 31));
    for (let now = 0; now < 120000; now += 50) {
      const cars = traffic.update(now);
      const byLane = new Map();
      for (const car of cars) byLane.set(car.kind, [...(byLane.get(car.kind) ?? []), car]);
      for (const lane of byLane.values()) {
        for (let index = 1; index < lane.length; index += 1) {
          const ahead = lane[index - 1];
          const car = lane[index];
          const lengthOf = c => VEHICLE_TYPES[c.type].length * road.carWidth * VEHICLE_TYPES[c.type].width;
          const gap = ahead.d - car.d - (lengthOf(ahead) + lengthOf(car)) / 2;
          assert.ok(gap > -1e-6, `${road.kind}: overlap of ${gap} at ${now}`);
        }
      }
    }
  }
});

test('every spawned vehicle is a known type with a colour, and traffic keeps flowing', () => {
  const traffic = createTraffic(CROSS, mulberry32(7));
  const seen = new Set();
  let finished = 0;
  let previous = 0;
  for (let now = 0; now < 180000; now += 100) {
    const cars = traffic.update(now);
    for (const car of cars) {
      assert.ok(VEHICLE_TYPES[car.type]);
      assert.equal(car.typeWidth, VEHICLE_TYPES[car.type].width);
      assert.match(car.color, /^#[0-9a-f]{6}$/);
      seen.add(car.type);
    }
    if (cars.length < previous) finished += previous - cars.length;
    previous = cars.length;
  }
  assert.ok(seen.size >= 4, [...seen].join(','));
  assert.ok(finished > 20, `only ${finished} vehicles made it across`);
});

test('cars and taxis are mirrored below wet roads', () => {
  const look = { light: 1, tint: [1, 1, 1], haze: 0, hazeColor: '#c9d6e6', night: 0, wet: 1, now: 0 };
  for (const type of ['sedan', 'jpntaxi']) {
    const projectedHeights = [];
    const cam = {
      height: 1,
      scaleAt: () => 1,
      project: (x, y, z) => {
        projectedHeights.push(y);
        return [x, y, z];
      }
    };
    drawVehicle3D(drawingContext(), { type, color: '#f4f5f7', seed: 1 }, { x: 0, z: 3, heading: 0, roll: 0 }, cam, look, 0.1);
    assert.ok(projectedHeights.some(y => y < 0), `${type}: expected a mirrored profile below the road surface`);
    assert.ok(projectedHeights.some(y => y > 0), `${type}: expected the normal profile above the road surface`);
  }
});
