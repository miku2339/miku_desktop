import assert from 'node:assert/strict';
import fs from 'node:fs';
import test from 'node:test';

import * as THREE from '../Wallpaper/companion/vendor/three.module.js';
import { Parser } from '../Wallpaper/companion/vendor/libs/mmdparser.module.js';
import { createWalking } from '../Wallpaper/companion/walking.js';

const modelPath = new URL('../Wallpaper/assets/companion-model/tda/miku.pmx', import.meta.url);

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

test('step count follows travel distance instead of behavior duration', () => {
  const rig = loadLegRig();
  const walking = createWalking(rig);

  walking.update({ walking: true, rootX: 0, destinationX: 9.744, delta: 1 / 30 });
  assert.equal(walking.status().stepCount, 4);

  walking.reset();
  walking.update({ walking: true, rootX: 0, destinationX: -18.56, delta: 1 / 30 });
  assert.equal(walking.status().stepCount, 8);
  assert.equal(walking.status().direction, -1);
});

for (const direction of [1, -1]) {
  test(`stance ankle stays fixed while walking ${direction > 0 ? 'right' : 'left'}`, () => {
    const rig = loadLegRig();
    const walking = createWalking(rig);
    const distance = 9.744;
    const previous = new Map();
    let comparedFrames = 0;

    for (let frame = 0; frame <= 120; frame += 1) {
      resetRig(rig.restPose);
      const rootX = direction * distance * frame / 120;
      rig.model.position.set(rootX, 0, 0);
      const pose = walking.update({
        walking: true,
        rootX,
        destinationX: direction * distance,
        delta: 1 / 30
      });
      rig.model.rotation.y = direction * 1.22 * pose.turn;
      rig.model.updateMatrixWorld(true);
      walking.solve();

      for (const side of ['左', '右']) {
        const foot = walking.status().feet[side];
        const actual = anklePose(rig, side);
        const prior = previous.get(side);
        if (foot.planted && prior?.planted) {
          assert.ok(
            actual.position.distanceTo(prior.position) < 0.02,
            `${side} phase ${walking.status().phase}: ${actual.position.distanceTo(prior.position)}`
          );
          assert.ok(actual.quaternion.angleTo(prior.quaternion) < 1e-4);
          comparedFrames += 1;
        }
        previous.set(side, { ...actual, planted: foot.planted });
      }
    }

    assert.ok(comparedFrames > 40);
  });
}

test('swing foot rises and returns to its neutral ankle height', () => {
  const rig = loadLegRig();
  const walking = createWalking(rig);
  const distance = 9.744;
  let highestLift = 0;
  let lastSwingHeight = null;

  for (let frame = 0; frame <= 120; frame += 1) {
    resetRig(rig.restPose);
    const rootX = distance * frame / 120;
    rig.model.position.set(rootX, 0, 0);
    const pose = walking.update({ walking: true, rootX, destinationX: distance, delta: 1 / 30 });
    rig.model.rotation.y = 1.22 * pose.turn;
    rig.model.updateMatrixWorld(true);
    walking.solve();
    for (const side of ['左', '右']) {
      const foot = walking.status().feet[side];
      if (!foot.planted) {
        const height = anklePose(rig, side).position.y - foot.groundY;
        highestLift = Math.max(highestLift, height);
        lastSwingHeight = height;
      }
    }
  }

  assert.ok(highestLift > 0.45);
  assert.ok(lastSwingHeight < 0.03);
});

test('sub-step moves keep lift and turn proportional to their distance', () => {
  const rig = loadLegRig();
  const walking = createWalking(rig);
  const distance = 0.5;
  let highestLift = 0;
  let strongestTurn = 0;
  let strongestStride = 0;

  for (let frame = 0; frame <= 60; frame += 1) {
    resetRig(rig.restPose);
    const rootX = distance * frame / 60;
    rig.model.position.set(rootX, 0, 0);
    const pose = walking.update({ walking: true, rootX, destinationX: distance, delta: 1 / 30 });
    strongestTurn = Math.max(strongestTurn, Math.abs(pose.turn));
    strongestStride = Math.max(strongestStride, Math.abs(pose.stride));
    rig.model.rotation.y = 1.22 * pose.turn;
    rig.model.updateMatrixWorld(true);
    walking.solve();
    for (const side of ['左', '右']) {
      const foot = walking.status().feet[side];
      if (!foot.planted) highestLift = Math.max(highestLift, anklePose(rig, side).position.y - foot.groundY);
    }
  }

  assert.equal(walking.status().stepCount, 2);
  assert.ok(highestLift < 0.15);
  assert.ok(strongestTurn < 0.3);
  assert.ok(strongestStride < 0.2);
});

test('touchdown keeps the rendered foot orientation continuous', () => {
  const rig = loadLegRig();
  const walking = createWalking(rig);
  const distance = 9.744;
  const previous = new Map();
  let touchdowns = 0;

  for (let frame = 0; frame < 120; frame += 1) {
    resetRig(rig.restPose);
    const rootX = distance * frame / 120;
    rig.model.position.set(rootX, 0, 0);
    const pose = walking.update({ walking: true, rootX, destinationX: distance, delta: 1 / 30 });
    rig.model.rotation.y = 1.22 * pose.turn;
    rig.model.updateMatrixWorld(true);
    walking.solve();
    if (walking.status().weight < 0.999) continue;
    for (const side of ['左', '右']) {
      const toe = rig.bones.get(`${side}足先EX`).getWorldPosition(new THREE.Vector3());
      const quaternion = rig.bones.get(`${side}足首D`).getWorldQuaternion(new THREE.Quaternion());
      const planted = walking.status().feet[side].planted;
      const prior = previous.get(side);
      if (planted && prior && !prior.planted) {
        assert.ok(toe.distanceTo(prior.toe) < 0.15);
        assert.ok(quaternion.angleTo(prior.quaternion) < 0.08);
        touchdowns += 1;
      }
      previous.set(side, { toe, quaternion, planted });
    }
  }

  assert.ok(touchdowns >= 3);
});

test('knees stay in the model forward bend hemisphere', () => {
  const rig = loadLegRig();
  const walking = createWalking(rig);
  const distance = 9.744;
  let checked = 0;

  for (let frame = 10; frame < 110; frame += 1) {
    resetRig(rig.restPose);
    const rootX = distance * frame / 120;
    rig.model.position.set(rootX, 0, 0);
    const pose = walking.update({ walking: true, rootX, destinationX: distance, delta: 1 / 30 });
    rig.model.rotation.y = 1.22 * pose.turn;
    rig.model.updateMatrixWorld(true);
    walking.solve();
    if (walking.status().weight < 0.999) continue;

    const forward = new THREE.Vector3(0, 0, 1).applyQuaternion(rig.model.getWorldQuaternion(new THREE.Quaternion()));
    for (const side of ['左', '右']) {
      const hip = rig.bones.get(`${side}足`).getWorldPosition(new THREE.Vector3());
      const knee = rig.bones.get(`${side}ひざ`).getWorldPosition(new THREE.Vector3());
      const ankle = rig.bones.get(`${side}足首`).getWorldPosition(new THREE.Vector3());
      const axis = ankle.clone().sub(hip).normalize();
      const kneeOffset = knee.clone().sub(hip).addScaledVector(axis, -knee.clone().sub(hip).dot(axis));
      const projectedForward = forward.clone().addScaledVector(axis, -forward.dot(axis));
      assert.ok(kneeOffset.dot(projectedForward) > -1e-5);
      checked += 1;
    }
  }
  assert.ok(checked > 80);
});

test('stopping steps both feet home before IK weight fades', () => {
  const rig = loadLegRig();
  const walking = createWalking(rig);
  const destinationX = 9.744;
  let rootX = 0;
  for (let frame = 0; frame <= 24; frame += 1) {
    resetRig(rig.restPose);
    rootX = destinationX * 0.38 * frame / 24;
    rig.model.position.x = rootX;
    const pose = walking.update({ walking: true, rootX, destinationX, delta: 1 / 30 });
    rig.model.rotation.y = 1.22 * pose.turn;
    rig.model.updateMatrixWorld(true);
    walking.solve();
  }

  let previousWeight = walking.status().weight;
  let previousFeet = null;
  let fadingFrames = 0;
  for (let frame = 0; frame < 50; frame += 1) {
    resetRig(rig.restPose);
    rig.model.position.x = rootX;
    const pose = walking.update({ walking: false, rootX, destinationX, delta: 1 / 30 });
    rig.model.rotation.y = 1.22 * pose.turn;
    rig.model.updateMatrixWorld(true);
    walking.solve();
    const status = walking.status();
    const feet = Object.fromEntries(['左', '右'].map(side => [
      side,
      rig.bones.get(`${side}足先EX`).getWorldPosition(new THREE.Vector3())
    ]));
    if (status.weight < previousWeight - 1e-6) {
      assert.ok(Object.values(status.feet).every(foot => foot.swing === 0));
      if (previousFeet) {
        for (const side of ['左', '右']) {
          const horizontal = Math.hypot(feet[side].x - previousFeet[side].x, feet[side].z - previousFeet[side].z);
          assert.ok(horizontal < 0.03, `${side} moved ${horizontal} while weight faded to ${status.weight}`);
        }
      }
      fadingFrames += 1;
    }
    previousWeight = status.weight;
    previousFeet = feet;
  }
  assert.ok(fadingFrames > 3);
});

test('interrupted swing lands before walking fades out', () => {
  const rig = loadLegRig();
  const walking = createWalking(rig);
  const destinationX = 9.744;
  let rootX = destinationX * 0.37;

  for (let frame = 0; frame <= 15; frame += 1) {
    resetRig(rig.restPose);
    rootX = destinationX * 0.37 * frame / 15;
    rig.model.position.x = rootX;
    walking.update({ walking: true, rootX, destinationX, delta: 1 / 30 });
    rig.model.updateMatrixWorld(true);
    walking.solve();
  }
  assert.ok(Object.values(walking.status().feet).some(foot => !foot.planted));

  let landedBeforeFade = false;
  for (let frame = 0; frame < 45; frame += 1) {
    resetRig(rig.restPose);
    rig.model.position.x = rootX;
    const pose = walking.update({ walking: false, rootX, destinationX, delta: 1 / 30 });
    rig.model.rotation.y = 1.22 * pose.turn;
    rig.model.updateMatrixWorld(true);
    walking.solve();
    const frameStatus = walking.status();
    if (frameStatus.weight > 0.99 && Object.values(frameStatus.feet).every(foot => foot.planted)) {
      landedBeforeFade = true;
    }
  }

  const status = walking.status();
  assert.equal(landedBeforeFade, true);
  assert.equal(status.active, false);
  assert.ok(status.weight < 0.02);
  for (const side of ['左', '右']) {
    const pose = anklePose(rig, side);
    assert.ok(pose.position.toArray().every(Number.isFinite));
    assert.ok(pose.quaternion.toArray().every(Number.isFinite));
  }
});

test('reversing an active move preserves the current foot references', () => {
  const rig = loadLegRig();
  const walking = createWalking(rig);
  const previousToes = new Map();
  let maxToeJump = 0;
  let maxJumpAt = null;
  let maxLift = 0;
  let maxLiftAt = null;
  let sampleIndex = 0;

  const frame = (rootX, destinationX, active = true) => {
    resetRig(rig.restPose);
    rig.model.position.x = rootX;
    const pose = walking.update({ walking: active, rootX, destinationX, delta: 1 / 30 });
    rig.model.rotation.y = pose.direction * 1.22 * pose.turn;
    rig.model.updateMatrixWorld(true);
    walking.solve();
    for (const side of ['左', '右']) {
      const toe = rig.bones.get(`${side}足先EX`).getWorldPosition(new THREE.Vector3());
      if (previousToes.has(side) && toe.distanceTo(previousToes.get(side)) > maxToeJump) {
        maxToeJump = toe.distanceTo(previousToes.get(side));
        maxJumpAt = { sampleIndex, side, status: walking.status() };
      }
      previousToes.set(side, toe);
      const foot = walking.status().feet[side];
      const lift = anklePose(rig, side).position.y - foot.groundY;
      if (lift > maxLift) {
        maxLift = lift;
        maxLiftAt = { sampleIndex, side, status: walking.status() };
      }
    }
    sampleIndex += 1;
  };

  for (let index = 0; index <= 30; index += 1) frame(2.5 * index / 30, 9.744);
  for (let index = 1; index <= 120; index += 1) frame(THREE.MathUtils.lerp(2.5, -5, index / 120), -5);
  for (let index = 0; index < 50; index += 1) frame(-5, -5, false);

  assert.ok(maxToeJump < 0.35, `reverse jump ${maxToeJump} ${JSON.stringify(maxJumpAt)}`);
  assert.ok(maxLift < 0.8, `reverse lift ${maxLift} ${JSON.stringify(maxLiftAt)}`);
  assert.equal(walking.status().active, false);
});

test('reversed gait rebases old foot offsets before the body outruns leg reach', () => {
  const rig = loadLegRig();
  const walking = createWalking(rig);
  let checkedFrames = 0;
  let maxTargetError = 0;
  let maxTargetErrorAt = null;
  const plantedTargetZ = new Map();

  const frame = (rootX, destinationX, checkTargets = false) => {
    resetRig(rig.restPose);
    rig.model.position.x = rootX;
    const pose = walking.update({ walking: true, rootX, destinationX, delta: 1 / 30 });
    rig.model.rotation.y = pose.direction * 1.22 * pose.turn;
    rig.model.updateMatrixWorld(true);
    walking.solve();
    const status = walking.status();
    if (!checkTargets || status.weight < 0.999 || status.recovering) return;
    for (const side of ['左', '右']) {
      const foot = status.feet[side];
      if (!foot.planted) {
        plantedTargetZ.delete(side);
        continue;
      }
      const actual = anklePose(rig, side).position;
      const target = new THREE.Vector3().fromArray(foot.targetWorld);
      const error = actual.distanceTo(target);
      if (error > maxTargetError) {
        maxTargetError = error;
        maxTargetErrorAt = { side, phase: status.phase };
      }
      if (plantedTargetZ.has(side)) {
        assert.ok(Math.abs(target.z - plantedTargetZ.get(side)) < 1e-6, `${side} stance target Z moved`);
      }
      plantedTargetZ.set(side, target.z);
      checkedFrames += 1;
    }
  };

  for (let index = 0; index <= 30; index += 1) frame(2.5 * index / 30, 9.744);
  for (let index = 1; index <= 90; index += 1) {
    frame(THREE.MathUtils.lerp(2.5, -5, index / 90), -5, index >= 30);
  }

  assert.ok(checkedFrames > 30);
  assert.ok(maxTargetError < 0.03, `target error ${maxTargetError} ${JSON.stringify(maxTargetErrorAt)}`);
});

test('retargeting to the current root steps staggered feet home before fading', () => {
  const rig = loadLegRig();
  const walking = createWalking(rig);
  const neutralX = Object.fromEntries(['左', '右'].map(side => [side, anklePose(rig, side).position.x]));
  const previousToes = new Map();
  let rootX = 0;
  let previousWeight = 0;
  let maxToeJump = 0;
  let maxToeJumpAt = null;
  let maxLift = 0;
  let homeBeforeFade = false;
  let frameIndex = 0;

  const frame = (destinationX) => {
    resetRig(rig.restPose);
    rig.model.position.x = rootX;
    const pose = walking.update({ walking: true, rootX, destinationX, delta: 1 / 30 });
    rig.model.rotation.y = pose.direction * 1.22 * pose.turn;
    rig.model.updateMatrixWorld(true);
    walking.solve();
    const status = walking.status();
    for (const side of ['左', '右']) {
      const toe = rig.bones.get(`${side}足先EX`).getWorldPosition(new THREE.Vector3());
      if (previousToes.has(side) && toe.distanceTo(previousToes.get(side)) > maxToeJump) {
        maxToeJump = toe.distanceTo(previousToes.get(side));
        maxToeJumpAt = { frameIndex, side, status };
      }
      previousToes.set(side, toe);
      maxLift = Math.max(maxLift, anklePose(rig, side).position.y - status.feet[side].groundY);
    }
    if (status.weight < previousWeight - 1e-6) {
      homeBeforeFade = ['左', '右'].every(side => (
        Math.abs(status.feet[side].targetWorld[0] - (rootX + neutralX[side])) < 0.03
      ));
    }
    previousWeight = status.weight;
    frameIndex += 1;
  };

  for (let index = 0; index <= 30; index += 1) {
    rootX = 2.5 * index / 30;
    frame(9.744);
  }
  for (let index = 0; index < 80; index += 1) frame(rootX + 0.005);

  assert.ok(maxToeJump < 0.35, `near-root retarget jump ${maxToeJump} ${JSON.stringify(maxToeJumpAt)}`);
  assert.ok(maxLift > 0.35, `near-root home lift ${maxLift}`);
  assert.equal(homeBeforeFade, true);
  assert.equal(walking.status().active, false);
});
