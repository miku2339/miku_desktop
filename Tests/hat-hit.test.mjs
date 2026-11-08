import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

import * as THREE from '../Wallpaper/companion/vendor/three.module.js';
import { createProps } from '../Wallpaper/companion/props.js';
import { createSleepPoser, stirEnvelope } from '../Wallpaper/companion/sleep-pose.js';

const companionSource = readFileSync(
  new URL('../Wallpaper/companion/companion.js', import.meta.url),
  'utf8'
);

function sourceSection(startMarker, endMarker) {
  const start = companionSource.indexOf(startMarker);
  const end = companionSource.indexOf(endMarker, start);
  if (start < 0 || end < 0) throw new Error(`Missing companion.js section: ${startMarker}`);
  return companionSource.slice(start, end);
}

const hitHelpersSource = sourceSection('function bodyBounds(', '\n\nconst euler');
const hatPlacementsSource = sourceSection('const HAT_PLACEMENT =', '\n\nfunction applyHoldPose(');
const sleepingSource = sourceSection('function updateSleepingModel(', '\n\n// How far her side');

const MODEL_SCALE = 0.93;
const SLEEP_SCALE = 0.75;
const SLEEP_BODY_HALF = 0.03;
const CAMERA_HEIGHT = 29;

function skinnedBody() {
  const geometry = new THREE.BoxGeometry(4, 8, 2);
  const count = geometry.getAttribute('position').count;
  const indices = new Uint16Array(count * 4);
  const weights = new Float32Array(count * 4);
  for (let index = 0; index < count; index += 1) weights[index * 4] = 1;
  geometry.setAttribute('skinIndex', new THREE.Uint16BufferAttribute(indices, 4));
  geometry.setAttribute('skinWeight', new THREE.Float32BufferAttribute(weights, 4));

  const model = new THREE.SkinnedMesh(
    geometry,
    new THREE.MeshBasicMaterial({ side: THREE.DoubleSide })
  );
  const head = new THREE.Bone();
  head.name = '頭';
  head.position.y = 4;
  model.add(head);
  model.bind(new THREE.Skeleton([head]));
  model.scale.setScalar(MODEL_SCALE);
  model.updateMatrixWorld(true);
  return { head, model };
}

function createHarness() {
  const { head, model } = skinnedBody();
  const props = createProps(THREE);
  const camera = new THREE.OrthographicCamera(-10, 10, 10, -10, 0.1, 100);
  camera.position.set(0, 0, 20);
  camera.lookAt(0, 0, 0);
  camera.updateProjectionMatrix();
  camera.updateMatrixWorld(true);

  const state = {
    behavior: 'idle',
    interactive: true,
    model,
    standingHeight: 0,
    turnOffset: 0
  };
  const sleepState = { lying: false, visibility: 1 };
  const roomGeometry = { bedHeadX: 0.93, bedSurfaceY: 0.79 };
  const raycaster = new THREE.Raycaster();
  const modelBox = new THREE.Box3();
  const context = vm.createContext({
    CAMERA_HEIGHT,
    CHEST_BONE: /^(upperBody2|tie)$/,
    HAIR_BONE: /hair/,
    LIMB_BONE: /arm|hand/,
    MODEL_SCALE,
    SLEEP_BODY_HALF,
    SLEEP_HIP_TILT: 0.2,
    SLEEP_SCALE,
    SLEEP_TAIL_SWING: 0.45,
    SKIRT_BONE: /skirt|leg/,
    THREE,
    camera,
    canvas: { getBoundingClientRect: () => ({ height: 1000, left: 0, top: 0, width: 1000 }) },
    dominantBone(hit) {
      if (Math.abs(hit?.point?.x ?? 0) > 1) return 'arm';
      if ((hit?.point?.y ?? -Infinity) > 1) return 'upperBody2';
      if ((hit?.point?.y ?? -Infinity) > -1) return 'skirt';
      return '';
    },
    floatSymbol() {},
    hitLocalPosition: new THREE.Vector3(),
    modelBox,
    pointerNdc: new THREE.Vector2(),
    props,
    raycaster,
    resetMorphs() {},
    resetSkeleton() {},
    roomGeometry,
    rotateBone() {},
    screenAnchorToWorld: value => value,
    setMorph() {},
    sleepPoser: createSleepPoser(() => 0.5),
    sleepState,
    stirEnvelope,
    sleepTouch: { stirSide: 1, stirStart: -Infinity },
    state,
    turning: { yaw: { v: 0, x: 0 } },
    updateHoverBlend() {},
    variety: { chance: () => false },
    walking: { reset() {} }
  });

  vm.runInContext(
    `${hatPlacementsSource}\nglobalThis.__hatPlacements = HAT_PLACEMENT;`,
    context,
    { filename: 'companion.js#hat-placements' }
  );
  vm.runInContext(
    `${hitHelpersSource}\nglobalThis.__hitHelpers = { bodyBounds, raycastCharacter, raycastWornHat };`,
    context,
    { filename: 'companion.js#hit-testing' }
  );
  vm.runInContext(
    `${sleepingSource}\nglobalThis.__updateSleepingModel = updateSleepingModel;`,
    context,
    { filename: 'companion.js#sleeping-model' }
  );

  return {
    camera,
    head,
    helpers: context.__hitHelpers,
    model,
    placements: context.__hatPlacements,
    props,
    roomGeometry,
    sleepState,
    state,
    updateSleepingModel: context.__updateSleepingModel
  };
}

function clientPoint(camera, x, y) {
  const point = new THREE.Vector3(x, y, 0).project(camera);
  return [(point.x + 1) * 500, (1 - point.y) * 500];
}

function belongsTo(root, object) {
  for (let current = object; current; current = current.parent) {
    if (current === root) return true;
  }
  return false;
}

function findHatHit(harness, name) {
  harness.props.wearHat(name, harness.head, harness.placements[name]);
  harness.model.updateMatrixWorld(true);
  const hat = harness.props.hats[name];
  const hatBox = new THREE.Box3().setFromObject(hat);
  const bodyBox = harness.helpers.bodyBounds(new THREE.Box3());
  const minimumY = Math.max(hatBox.min.y, bodyBox.max.y + 0.02);

  for (let row = 0; row < 20; row += 1) {
    const y = THREE.MathUtils.lerp(minimumY, hatBox.max.y, (row + 0.5) / 20);
    for (let column = 0; column < 20; column += 1) {
      const x = THREE.MathUtils.lerp(hatBox.min.x, hatBox.max.x, (column + 0.5) / 20);
      const client = clientPoint(harness.camera, x, y);
      const result = harness.helpers.raycastCharacter(...client);
      if (result?.zone === 'head' && belongsTo(hat, result.hit.object)) return { client, result };
    }
  }
  return null;
}

function hitAtWorld(harness, x, y) {
  return harness.helpers.raycastCharacter(...clientPoint(harness.camera, x, y));
}

function closeTo(actual, expected, epsilon = 1e-9) {
  assert.ok(Math.abs(actual - expected) <= epsilon, `${actual} should be close to ${expected}`);
}

test('body bounds ignore hats attached to the skinned model', () => {
  const harness = createHarness();
  harness.props.wearHat('witch', harness.head, harness.placements.witch);
  harness.model.updateMatrixWorld(true);

  const body = harness.helpers.bodyBounds(new THREE.Box3());
  const withHat = new THREE.Box3().setFromObject(harness.model);

  closeTo(body.max.y - body.min.y, 8 * MODEL_SCALE);
  assert.ok(withHat.max.y > body.max.y);
  assert.ok(withHat.max.x - withHat.min.x > body.max.x - body.min.x);
});

test('every visible hat raycasts as head and hidden hats do not catch the ray', () => {
  const harness = createHarness();
  let witchHit = null;

  for (const name of ['santa', 'witch', 'party', 'beanie']) {
    const hit = findHatHit(harness, name);
    assert.ok(hit, `${name} should expose a visible head hit`);
    if (name === 'witch') witchHit = hit;
  }

  harness.props.wearHat(null, harness.head, null);
  harness.model.updateMatrixWorld(true);
  assert.equal(harness.helpers.raycastWornHat(), null);
  assert.equal(harness.helpers.raycastCharacter(...witchHit.client), null);
});

test('hats do not change chest, hand or skirt classification', () => {
  const harness = createHarness();
  const samples = [
    { point: [0, 1.5], zone: 'chest' },
    { point: [1.5, 1], zone: 'hand' },
    { point: [0, 0], zone: 'skirt' }
  ];

  for (const sample of samples) {
    assert.equal(hitAtWorld(harness, ...sample.point)?.zone, sample.zone);
  }
  for (const name of ['santa', 'witch', 'party', 'beanie']) {
    harness.props.wearHat(name, harness.head, harness.placements[name]);
    harness.model.updateMatrixWorld(true);
    for (const sample of samples) {
      assert.equal(hitAtWorld(harness, ...sample.point)?.zone, sample.zone, `${name}: ${sample.zone}`);
    }
  }
});

test('sleep height and bed placement use body height without hats', () => {
  const harness = createHarness();
  harness.props.wearHat('witch', harness.head, harness.placements.witch);
  harness.model.updateMatrixWorld(true);
  const withHatHeight = new THREE.Box3().setFromObject(harness.model).getSize(new THREE.Vector3()).y;
  const expectedStandingHeight = 8 * MODEL_SCALE;

  harness.sleepState.lying = true;
  harness.updateSleepingModel(1);

  closeTo(harness.state.standingHeight, expectedStandingHeight);
  assert.ok(harness.state.standingHeight < withHatHeight);
  closeTo(harness.model.scale.x, MODEL_SCALE * SLEEP_SCALE);
  const sleepHeight = expectedStandingHeight * SLEEP_SCALE;
  closeTo(harness.model.position.x, harness.roomGeometry.bedHeadX - sleepHeight * 0.97);
  closeTo(
    harness.model.position.y,
    harness.camera.position.y
      + CAMERA_HEIGHT * (0.5 - harness.roomGeometry.bedSurfaceY)
      + sleepHeight * SLEEP_BODY_HALF
  );
});
