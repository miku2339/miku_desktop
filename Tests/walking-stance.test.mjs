import assert from 'node:assert/strict';
import fs from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

import * as THREE from '../Wallpaper/companion/vendor/three.module.js';
import { Parser } from '../Wallpaper/companion/vendor/libs/mmdparser.module.js';
import { createWalking } from '../Wallpaper/companion/walking.js';

const modelPath = new URL('../Wallpaper/assets/companion-model/tda/miku.pmx', import.meta.url);
const companionSource = fs.readFileSync(new URL('../Wallpaper/companion/companion.js', import.meta.url), 'utf8');

function sourceFor(name) {
  const start = companionSource.indexOf(`function ${name}(`);
  assert.notEqual(start, -1, `${name} must exist`);
  const body = companionSource.indexOf(') {', start) + 2;
  let depth = 0;
  for (let index = body; index < companionSource.length; index += 1) {
    if (companionSource[index] === '{') depth += 1;
    else if (companionSource[index] === '}') depth -= 1;
    if (depth === 0) return companionSource.slice(start, index + 1);
  }
  throw new Error(`Could not extract ${name}`);
}

function integratedStanceCall({ gaitActive = false, gaitDisabled = false, hopLift = 0, turnSpeed = 0 } = {}) {
  let call = null;
  const context = vm.createContext({
    state: { hopLift },
    turning: { yaw: { v: turnSpeed } },
    springDelta: 1 / 60,
    walking: { holdStance: options => { call = options; } }
  });
  vm.runInContext(`${sourceFor('updateStandingStance')}\nupdateStandingStance({ active: ${gaitActive} }, ${gaitDisabled});`, context);
  return call ? { ...call } : call;
}

function loadLegRig() {
  const bytes = fs.readFileSync(modelPath);
  const buffer = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
  const parsed = new Parser().parsePmx(buffer, true);
  const model = new THREE.Object3D();
  const allBones = parsed.bones.map(data => {
    const bone = new THREE.Bone();
    bone.name = data.name;
    return bone;
  });

  parsed.bones.forEach((data, index) => {
    const bone = allBones[index];
    bone.position.fromArray(data.position);
    if (data.parentIndex >= 0) {
      bone.position.sub(new THREE.Vector3().fromArray(parsed.bones[data.parentIndex].position));
      allBones[data.parentIndex].add(bone);
    } else {
      model.add(bone);
    }
  });
  model.scale.setScalar(0.93);
  const bones = new Map(allBones.map(bone => [bone.name, bone]));
  const restPose = new Map(allBones.map(bone => [bone, {
    position: bone.position.clone(),
    quaternion: bone.quaternion.clone(),
    scale: bone.scale.clone()
  }]));
  return { model, bones, restPose };
}

function resetRig(restPose) {
  for (const [bone, rest] of restPose) {
    bone.position.copy(rest.position);
    bone.quaternion.copy(rest.quaternion);
    bone.scale.copy(rest.scale);
  }
}

function anklePose(rig, side) {
  const bone = rig.bones.get(`${side}足首D`);
  return {
    position: bone.getWorldPosition(new THREE.Vector3()),
    quaternion: bone.getWorldQuaternion(new THREE.Quaternion())
  };
}

// Standing still: gestures sway the hips but the feet stay planted.
function swayHips(rig, x, twist) {
  const center = rig.bones.get('センター');
  center.position.x += x;
  const lower = rig.bones.get('下半身');
  if (lower) lower.quaternion.multiply(new THREE.Quaternion().setFromEuler(new THREE.Euler(0, twist, 0)));
}

test('planted feet do not slide while the hips sway', () => {
  const rig = loadLegRig();
  const walking = createWalking(rig);
  resetRig(rig.restPose);
  walking.holdStance({ active: true, delta: 1 });
  const start = ['左', '右'].map(side => anklePose(rig, side).position);
  for (const [x, twist] of [[0.12, 0.08], [-0.12, -0.08], [0.06, 0.04]]) {
    resetRig(rig.restPose);
    swayHips(rig, x, twist);
    rig.model.updateMatrixWorld(true);
    walking.holdStance({ active: true, delta: 1 / 30 });
    ['左', '右'].forEach((side, index) => {
      const now = anklePose(rig, side).position;
      assert.ok(Math.hypot(now.x - start[index].x, now.z - start[index].z) < 0.06, `${side} foot stays put (${x})`);
    });
  }
});

test('drifting too far makes her step instead of sliding', () => {
  const rig = loadLegRig();
  const walking = createWalking(rig);
  resetRig(rig.restPose);
  walking.holdStance({ active: true, delta: 1 });
  const restY = Math.max(anklePose(rig, '左').position.y, anklePose(rig, '右').position.y);
  rig.model.position.x += 0.8;
  resetRig(rig.restPose);
  rig.model.updateMatrixWorld(true);
  walking.holdStance({ active: true, delta: 1 / 30 });
  assert.equal(walking.stanceStatus().stepping, true);
  let lifted = 0;
  for (let i = 0; i < 20; i++) {
    resetRig(rig.restPose);
    rig.model.updateMatrixWorld(true);
    walking.holdStance({ active: true, delta: 1 / 30 });
    lifted = Math.max(lifted, anklePose(rig, '左').position.y, anklePose(rig, '右').position.y);
  }
  assert.equal(walking.stanceStatus().stepping, false);
  assert.ok(lifted > restY + 0.05, 'a foot is lifted on the way');
});

test('picked up: the feet go with her at once', () => {
  const rig = loadLegRig();
  const walking = createWalking(rig);
  resetRig(rig.restPose);
  walking.holdStance({ active: true, delta: 1 });
  walking.holdStance({ active: false, release: true, delta: 1 / 30 });
  assert.equal(walking.stanceStatus().weight, 0);
});

test('reset forgets the old stance and plants again where she is', () => {
  const rig = loadLegRig();
  const walking = createWalking(rig);
  resetRig(rig.restPose);
  walking.holdStance({ active: true, delta: 1 });
  const before = anklePose(rig, '左').position;

  walking.reset();
  assert.equal(walking.stanceStatus().weight, 0);
  rig.model.position.x += 0.8;
  resetRig(rig.restPose);
  rig.model.updateMatrixWorld(true);
  walking.holdStance({ active: true, delta: 1 });

  const after = anklePose(rig, '左').position;
  assert.equal(walking.stanceStatus().stepping, false);
  assert.ok(Math.abs((after.x - before.x) - 0.8) < 0.01, 'the new stance follows the moved model');
});

test('a fast turn releases immediately and re-plants at the new heading', () => {
  assert.deepEqual(integratedStanceCall({ turnSpeed: 1.5 }), {
    active: false,
    release: true,
    delta: 1 / 60
  });

  const rig = loadLegRig();
  const walking = createWalking(rig);
  resetRig(rig.restPose);
  walking.holdStance({ active: true, delta: 1 });

  rig.model.rotation.y = 1.2;
  resetRig(rig.restPose);
  rig.model.updateMatrixWorld(true);
  walking.holdStance({ active: false, release: true, delta: 1 / 60 });
  const released = walking.stanceStatus();
  assert.equal(released.weight, 0);
  assert.equal(released.stepping, false);

  walking.holdStance({ active: true, delta: 1 });
  assert.equal(walking.stanceStatus().stepping, false);
  for (const side of ['左', '右']) {
    const planted = walking.stanceStatus().targets[side];
    const ankle = anklePose(rig, side).position.toArray();
    assert.ok(Math.hypot(planted[0] - ankle[0], planted[2] - ankle[2]) < 0.06, `${side} foot re-plants after turning`);
  }
});

test('a hop releases the stance in the same frame', () => {
  assert.deepEqual(integratedStanceCall({ hopLift: 0.002 }), {
    active: false,
    release: true,
    delta: 1 / 60
  });
});
