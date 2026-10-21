import test from 'node:test';
import assert from 'node:assert/strict';
import { ROAD_LIMITS, spawnVehicle, vehicleAlpha, vehiclePosition, VEHICLE_TYPES } from '../Wallpaper/companion/vehicles.js';

const sequence = values => {
  let index = 0;
  return () => values[index++ % values.length];
};

test('oncoming traffic starts far away and grows as it approaches', () => {
  const car = spawnVehicle({ direction: 'toward', index: 1 }, 0, sequence([0.1, 0.5, 0.5, 0.3]));
  const far = vehiclePosition(car, 0);
  const later = vehiclePosition(car, 5000);
  assert.equal(far.z, ROAD_LIMITS.FARTHEST);
  assert.ok(later.scale > far.scale);
  assert.equal(far.done, false);
});

test('constant road speed: the picture moves slowly far away and quickly up close', () => {
  const car = spawnVehicle({ direction: 'toward' }, 0, sequence([0.2, 0.5, 0.5, 0.3]));
  const step = 1000;
  const scaleAt = t => vehiclePosition(car, t).scale;
  const farGrowth = scaleAt(step) - scaleAt(0);
  const travel = (ROAD_LIMITS.FARTHEST - 2) / car.speed * 1000;
  const nearGrowth = scaleAt(travel + step) - scaleAt(travel);
  assert.ok(nearGrowth > farGrowth * 10, `${nearGrowth} vs ${farGrowth}`);
});

test('traffic heading away starts at the camera and leaves at the far end', () => {
  const car = spawnVehicle({ direction: 'away' }, 0, sequence([0.5]));
  assert.equal(vehiclePosition(car, 0).z, ROAD_LIMITS.NEAREST);
  const end = (ROAD_LIMITS.FARTHEST - ROAD_LIMITS.NEAREST) / car.speed * 1000;
  assert.equal(vehiclePosition(car, end + 10).done, true);
});

test('a newcomer never catches up with the vehicle ahead in its lane', () => {
  const random = sequence([0.9, 0.99, 0.5, 0.99, 0.2]);
  const lane = { direction: 'toward' };
  const leader = spawnVehicle(lane, 0, sequence([0.1, 0.1, 0.1, 0.0]));
  assert.equal(spawnVehicle(lane, 500, random, leader), null, 'too close to its entry point');
  const follower = spawnVehicle(lane, 6000, random, leader);
  assert.ok(follower);
  assert.ok(follower.speed <= leader.speed);
  for (let t = 6000; t < 30000; t += 250) {
    const a = vehiclePosition(leader, t);
    const b = vehiclePosition(follower, t);
    if (a.done) break;
    assert.ok(b.z > a.z, `follower overtook at ${t}`);
  }
});

test('fades in from the distance and out right at the camera', () => {
  assert.equal(vehicleAlpha(ROAD_LIMITS.FARTHEST), 0);
  assert.equal(vehicleAlpha(ROAD_LIMITS.NEAREST), 0);
  assert.equal(vehicleAlpha(3), 1);
});

test('every vehicle type is a known, sized type with a colour', () => {
  const random = sequence([0.01, 0.2, 0.4, 0.6, 0.8, 0.99, 0.33, 0.66]);
  for (let index = 0; index < 40; index += 1) {
    const car = spawnVehicle({ direction: index % 2 ? 'away' : 'toward' }, 0, random);
    assert.ok(VEHICLE_TYPES[car.type]);
    assert.equal(car.typeWidth, VEHICLE_TYPES[car.type].width);
    assert.match(car.color, /^#[0-9a-f]{6}$/);
  }
});
