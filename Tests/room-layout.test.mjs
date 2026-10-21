import test from 'node:test';
import assert from 'node:assert/strict';
import {
  canUseRoomBed,
  loadRoomLayout,
  normalizeRoomLayout,
  roomAmbientFeatures,
  roomViewportGeometry
} from '../Wallpaper/companion/room-layout.js';

const calibrated = {
  sleepReady: true,
  files: {
    day: { width: 2560, height: 1600 }
  },
  coordinates: {
    rectFormat: 'x,y,width,height',
    bedHeadX: 0.9,
    bedSurfaceY: 0.8,
    windowBounds: [0.08, 0.12, 0.26, 0.32],
    wallFloorBoundaryY: 0.61,
    clearForeground: [0.05, 0.7, 0.43, 0.3],
    suggestedFootY: 0.915
  }
};

test('missing or malformed metadata stays safe and uses room defaults', async () => {
  const missing = await loadRoomLayout('missing.json', async () => { throw new Error('missing'); });
  assert.equal(missing.sleepReady, false);
  assert.equal(canUseRoomBed(missing, true), false);
  assert.deepEqual(missing.imageSize, [2560, 1600]);
  assert.deepEqual(missing.coordinates.clearForeground, [0.04, 0.7, 0.44, 0.3]);

  const malformed = normalizeRoomLayout({
    sleepReady: 'true',
    coordinates: { bedHeadX: 8, windowBounds: [0, 0, 2, 2] }
  });
  assert.equal(malformed.sleepReady, false);
  assert.equal(malformed.coordinates.bedHeadX, 0.93);
  assert.deepEqual(malformed.coordinates.windowBounds, [0.06, 0.1, 0.3, 0.36]);
});

test('sleepReady only enables the bed after the room pictures have loaded', () => {
  const layout = normalizeRoomLayout(calibrated);
  assert.equal(canUseRoomBed(layout, false), false);
  assert.equal(canUseRoomBed(layout, true), true);
});

test('room coordinates drive the bed, clear floor and ambient window', () => {
  const layout = normalizeRoomLayout(calibrated);
  const geometry = roomViewportGeometry(layout, 1600, 1000);
  assert.equal(geometry.bedHeadX, 0.9);
  assert.equal(geometry.bedSurfaceY, 0.8);
  assert.equal(geometry.suggestedFootY, 0.915);
  assert.deepEqual(geometry.clearForeground, [0.05, 0.7, 0.43, 0.3]);

  assert.deepEqual(roomAmbientFeatures(layout), {
    size: [2560, 1600],
    windows: [[0.08, 0.12, 0.34, 0.44]],
    floor: 0.61
  });
});

test('cover mapping compensates for the MacBook 14 aspect ratio', () => {
  const layout = normalizeRoomLayout(calibrated);
  const geometry = roomViewportGeometry(layout, 1540, 1000);
  const drawnWidth = 1.6 / 1.54;
  const offsetX = (1 - drawnWidth) / 2;

  assert.ok(Math.abs(geometry.bedHeadX - (offsetX + 0.9 * drawnWidth)) < 1e-12);
  assert.ok(Math.abs(geometry.clearForeground[0] - (offsetX + 0.05 * drawnWidth)) < 1e-12);
  assert.ok(Math.abs(geometry.clearForeground[2] - 0.43 * drawnWidth) < 1e-12);
  assert.equal(geometry.bedSurfaceY, 0.8);
  assert.equal(geometry.suggestedFootY, 0.915);
});
