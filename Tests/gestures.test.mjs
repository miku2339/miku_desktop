import assert from 'node:assert/strict';
import fs from 'node:fs';
import test from 'node:test';

import * as THREE from '../Wallpaper/companion/vendor/three.module.js';
import { Parser } from '../Wallpaper/companion/vendor/libs/mmdparser.module.js';
import { createGestures } from '../Wallpaper/companion/gestures.js';

const modelPath = new URL('../Wallpaper/assets/companion-model/tda/miku.pmx', import.meta.url);

function loadRig() {
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

  const bones = new Map(allBones.map(bone => [bone.name, bone]));
  const restPose = new Map(allBones.map(bone => [bone, {
    position: bone.position.clone(),
    quaternion: bone.quaternion.clone(),
    scale: bone.scale.clone()
  }]));
  return { model, bones, boneData: parsed.bones, allBones, restPose };
}

function resetRig(rig) {
  for (const [bone, rest] of rig.restPose) {
    bone.position.copy(rest.position);
    bone.quaternion.copy(rest.quaternion);
    bone.scale.copy(rest.scale);
  }
}

const euler = new THREE.Euler();
const quaternion = new THREE.Quaternion();
const twistAxis = new THREE.Vector3();

function rotateBone(rig, name, x = 0, y = 0, z = 0, weight = 1) {
  const bone = rig.bones.get(name);
  if (!bone || weight === 0) return;
  euler.set(x * weight, y * weight, z * weight, 'XYZ');
  quaternion.setFromEuler(euler);
  bone.quaternion.multiply(quaternion);
}

function twistBone(rig, name, childName, angle, weight = 1) {
  const bone = rig.bones.get(name);
  const child = rig.bones.get(childName);
  if (!bone || !child || weight === 0) return;
  const childRest = rig.restPose.get(child);
  twistAxis.copy(childRest.position);
  let parent = child.parent;
  while (parent && parent !== bone) {
    const parentRest = rig.restPose.get(parent);
    twistAxis.multiply(parentRest.scale).applyQuaternion(parentRest.quaternion).add(parentRest.position);
    parent = parent.parent;
  }
  if (parent !== bone || twistAxis.lengthSq() < 1e-8) return;
  quaternion.setFromAxisAngle(twistAxis.normalize(), angle * weight);
  bone.quaternion.multiply(quaternion);
}

function applyGrantRotations(rig) {
  const identity = new THREE.Quaternion();
  const grantRotation = new THREE.Quaternion();
  rig.boneData.forEach((data, index) => {
    const grant = data.grant;
    if (!grant || grant.isLocal || !grant.affectRotation) return;
    const bone = rig.allBones[index];
    const source = rig.allBones[grant.parentIndex];
    const rest = rig.restPose.get(source);
    if (!bone || !source || !rest) return;
    quaternion.copy(rest.quaternion).invert().multiply(source.quaternion);
    grantRotation.slerpQuaternions(identity, quaternion, grant.ratio);
    bone.quaternion.multiply(grantRotation);
  });
}

function applyBaseArms(rig) {
  rotateBone(rig, '左腕', 0.03, 0, -0.50);
  rotateBone(rig, '右腕', -0.03, 0, 0.50);
  rotateBone(rig, '左ひじ', 0.04, 0.02, 0.12);
  rotateBone(rig, '右ひじ', -0.04, -0.02, -0.12);
  rotateBone(rig, '左手首', 0.03, 0, -0.06);
  rotateBone(rig, '右手首', -0.03, 0, 0.06);
}

function smoothstep(value) {
  const clamped = Math.min(1, Math.max(0, value));
  return clamped * clamped * (3 - 2 * clamped);
}

function poseClap(rig, elapsed) {
  resetRig(rig);
  applyBaseArms(rig);
  const gestures = createGestures({
    rotateBone: (...args) => rotateBone(rig, ...args),
    twistBone: (...args) => twistBone(rig, ...args),
    offsetBone: () => {},
    setMorph: () => {},
    setSmile: () => {},
    scaleMorph: () => {},
    blinkAmount: () => 0,
    easeBetween: (value, start, end) => smoothstep((value - start) / (end - start)),
    envelope: () => 1,
    symbol: () => {},
    say: () => {},
    setTurnOffset: () => {},
    lift: () => {}
  });
  gestures.clap(0.5, elapsed, {});
  applyGrantRotations(rig);
  rig.model.updateMatrixWorld(true);
}

function handPose(rig, side) {
  const wrist = rig.bones.get(`${side}手首`);
  const palm = rig.bones.get(`${side}中指１`);
  const elbow = rig.bones.get(`${side}ひじ`).getWorldPosition(new THREE.Vector3());
  const fingertip = rig.bones.get(`${side}中指３`).getWorldPosition(new THREE.Vector3());
  const index = rig.bones.get(`${side}人指１`).getWorldPosition(new THREE.Vector3());
  const little = rig.bones.get(`${side}小指１`).getWorldPosition(new THREE.Vector3());
  const wristPosition = wrist.getWorldPosition(new THREE.Vector3());
  const palmPosition = palm.getWorldPosition(new THREE.Vector3());
  return {
    wrist: wristPosition,
    palm: palmPosition,
    elbow,
    fingertip,
    normal: palmPosition.clone().sub(wristPosition).cross(index.sub(little)).normalize(),
    wristBend: rig.restPose.get(wrist).quaternion.angleTo(wrist.quaternion)
  };
}

test('clap meets and separates open palms in front of the chest without crossing wrists', t => {
  const rig = loadRig();
  const closedElapsed = 0.5 / 2.6;

  poseClap(rig, closedElapsed);
  const closedLeft = handPose(rig, '左');
  const closedRight = handPose(rig, '右');
  const closedGap = closedLeft.palm.distanceTo(closedRight.palm);

  t.diagnostic(`vertical left elbow/palm/tip ${closedLeft.elbow.y.toFixed(3)}/${closedLeft.palm.y.toFixed(3)}/${closedLeft.fingertip.y.toFixed(3)}, right ${closedRight.elbow.y.toFixed(3)}/${closedRight.palm.y.toFixed(3)}/${closedRight.fingertip.y.toFixed(3)}`);
  assert.ok(closedLeft.wrist.x - closedRight.wrist.x > 0.6, `wrists too close (the cuffs collide) or crossed at clap contact: ${closedLeft.wrist.x}, ${closedRight.wrist.x}; palms ${closedLeft.palm.toArray()}, ${closedRight.palm.toArray()}; gap ${closedGap}`);
  assert.ok(Math.abs(closedLeft.palm.y - 14.9) < 1.2, `left palm height ${closedLeft.palm.y}`);
  assert.ok(Math.abs(closedRight.palm.y - 14.9) < 1.2, `right palm height ${closedRight.palm.y}`);
  assert.ok(closedLeft.palm.z > 0.8 && closedRight.palm.z > 0.8, 'palms are not in front of the chest');
  assert.ok(closedGap < 0.9, `closed palm gap ${closedGap}: ${closedLeft.wrist.toArray()}, ${closedRight.wrist.toArray()}; palms ${closedLeft.palm.toArray()}, ${closedRight.palm.toArray()}`);
  assert.ok(Math.abs(closedLeft.palm.y - closedRight.palm.y) < 0.3, 'palms do not meet at the same height');
  for (const hand of [closedLeft, closedRight]) {
    assert.ok(hand.fingertip.y > hand.palm.y + 0.2, `middle finger points down: ${hand.palm.y} -> ${hand.fingertip.y}`);
    assert.ok(hand.palm.y > hand.elbow.y + 0.15, `forearm does not rise toward the palm: ${hand.elbow.y} -> ${hand.palm.y}`);
  }
  assert.ok(Math.abs(closedLeft.normal.x) > 0.65 && Math.abs(closedRight.normal.x) > 0.65, `palm planes do not face across the chest: ${closedLeft.normal.toArray()}, ${closedRight.normal.toArray()}`);
  // Palms, not the backs of the hands, meet: on this rig that is a negative x normal for both
  // (the index-to-little axis flips between hands, so the cross product doesn't mirror).
  assert.ok(closedLeft.normal.x < 0 && closedRight.normal.x < 0, `the backs of the hands meet instead of the palms: ${closedLeft.normal.toArray()}, ${closedRight.normal.toArray()}`);
  assert.ok(closedLeft.wristBend < 0.35 && closedRight.wristBend < 0.35, 'wrist bend is too sharp');

  poseClap(rig, 0);
  const openLeft = handPose(rig, '左');
  const openRight = handPose(rig, '右');
  const openGap = openLeft.palm.distanceTo(openRight.palm);
  assert.ok(openLeft.wrist.x > openRight.wrist.x, 'wrists cross while hands separate');
  assert.ok(openGap > closedGap + 0.35, `palm gap does not animate: ${closedGap} -> ${openGap}`);
  t.diagnostic(`closed gap ${closedGap.toFixed(3)}, open gap ${openGap.toFixed(3)}, palms y ${closedLeft.palm.y.toFixed(3)}/${closedRight.palm.y.toFixed(3)}, z ${closedLeft.palm.z.toFixed(3)}/${closedRight.palm.z.toFixed(3)}, wrist x ${closedLeft.wrist.x.toFixed(3)}/${closedRight.wrist.x.toFixed(3)}, normals x ${closedLeft.normal.x.toFixed(3)}/${closedRight.normal.x.toFixed(3)}, wrist bend ${closedLeft.wristBend.toFixed(3)}/${closedRight.wristBend.toFixed(3)}`);
});

function poseGesture(rig, name, progress, variant = {}) {
  resetRig(rig);
  applyBaseArms(rig);
  const gestures = createGestures({
    rotateBone: (...args) => rotateBone(rig, ...args),
    twistBone: (...args) => twistBone(rig, ...args),
    offsetBone: () => {},
    setMorph: () => {},
    setSmile: () => {},
    scaleMorph: () => {},
    blinkAmount: () => 0,
    easeBetween: (value, start, end) => smoothstep((value - start) / (end - start)),
    envelope: () => 1,
    symbol: () => {},
    say: () => {},
    setTurnOffset: () => {},
    lift: () => {}
  });
  gestures[name](progress, 0, { side: '右', ...variant });
  applyGrantRotations(rig);
  rig.model.updateMatrixWorld(true);
}

// Which way the palm faces: the way the fingertips move when the fingers start to curl
// (towards the palm: -z on the left, +z on the right), minus any movement along the hand.
function palmFacing(rig, side) {
  const world = name => rig.bones.get(`${side}${name}`).getWorldPosition(new THREE.Vector3());
  const wrist = world('手首');
  const knuckle = world('中指１');
  const tip = world('中指３');
  const along = knuckle.clone().sub(wrist).normalize();
  for (const finger of ['人指', '中指', '薬指', '小指']) rotateBone(rig, `${side}${finger}１`, 0, 0, (side === '右' ? 1 : -1) * 0.1);
  rig.model.updateMatrixWorld(true);
  const moved = world('中指３').sub(tip);
  const palm = moved.addScaledVector(along, -moved.dot(along)).normalize();
  return { palm, along, centre: wrist.clone().lerp(knuckle, 0.7), elbow: world('ひじ'), wrist };
}

test('hands by the face show the palm the right way, not the back of the hand or the cuff', () => {
  const rig = loadRig();
  for (const [name, progress] of [['yawn', 0.4], ['think', 0.5], ['laugh', 0.5], ['surprised', 0.5]]) {
    poseGesture(rig, name, progress, { style: 'plain' });
    const sides = name === 'surprised' ? ['左', '右'] : ['右'];
    for (const side of sides) {
      const hand = palmFacing(rig, side);
      assert.ok(hand.palm.z < -0.5, `${name} ${side}: the palm does not face her (back of the hand to her face) ${hand.palm.toArray()}`);
      assert.ok(hand.along.y > 0.5, `${name} ${side}: fingers point into her face instead of up ${hand.along.toArray()}`);
      assert.ok(hand.centre.z > 1.3, `${name} ${side}: hand is behind her face (${hand.centre.z})`);
      const forearm = hand.wrist.clone().sub(hand.elbow).normalize();
      assert.ok(forearm.y > 0.5, `${name} ${side}: forearm points at the camera ${forearm.toArray()}`);
    }
    if (name === 'surprised') {
      const left = palmFacing(rig, '左');
      const right = palmFacing(rig, '右');
      assert.ok(left.elbow.x > right.elbow.x + 1, 'forearms cross in front of her chest');
    }
  }
});

test('the idol "V" shows the palm and catching the rain holds the palm up', () => {
  const rig = loadRig();
  poseGesture(rig, 'idolPose', 0.5);
  const v = palmFacing(rig, '右');
  assert.ok(v.palm.z > 0.6, `idol V: palm does not face the front ${v.palm.toArray()}`);
  assert.ok(v.along.y > 0.5, `idol V: fingers do not point up ${v.along.toArray()}`);
  poseGesture(rig, 'skyLook', 0.5);
  const sky = palmFacing(rig, '右');
  assert.ok(sky.palm.y > 0.7, `rain check: palm does not face up ${sky.palm.toArray()}`);
});
