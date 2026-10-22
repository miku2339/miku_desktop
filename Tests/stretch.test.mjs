import assert from 'node:assert/strict';
import fs from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

import * as THREE from '../Wallpaper/companion/vendor/three.module.js';
import { Parser } from '../Wallpaper/companion/vendor/libs/mmdparser.module.js';

const companionSource = fs.readFileSync(new URL('../Wallpaper/companion/companion.js', import.meta.url), 'utf8');
const modelPath = new URL('../Wallpaper/assets/companion-model/tda/miku.pmx', import.meta.url);

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

function createHarness() {
  const rig = loadRig();
  const inputs = [];
  const context = vm.createContext({
    THREE,
    smoothstep,
    rotateBone: (...args) => {
      inputs.push(['rotate', ...args]);
      rotateBone(rig, ...args);
    },
    twistBone: (...args) => {
      inputs.push(['twist', ...args]);
      twistBone(rig, ...args);
    },
    offsetBone: (name, x = 0, y = 0, z = 0, weight = 1) => {
      inputs.push(['offset', name, x, y, z, weight]);
      const bone = rig.bones.get(name);
      if (bone && weight !== 0) bone.position.addScaledVector(new THREE.Vector3(x, y, z), weight);
    },
    setMorph: (...args) => { inputs.push(['morph', ...args]); },
    setSmile: (...args) => { inputs.push(['smile', ...args]); },
    blinkAmount: elapsed => 0.04 + 0.02 * Math.sin(elapsed)
  });
  vm.runInContext(`${sourceFor('applyStretch')}\nglobalThis.applyStretch = applyStretch;`, context, {
    filename: 'companion.js#applyStretch'
  });

  function pose(progress, style = 'plain', elapsed = progress * 5.2) {
    resetRig(rig);
    applyBaseArms(rig);
    inputs.length = 0;
    context.applyStretch(progress, { style, flip: 1 }, elapsed);
    applyGrantRotations(rig);
    rig.model.updateMatrixWorld(true);
    return inputs.slice();
  }

  return { rig, pose };
}

function boneSnapshot(rig, names) {
  return names.flatMap(name => {
    const bone = rig.bones.get(name);
    return [...bone.position.toArray(), ...bone.quaternion.toArray()];
  });
}

function worldPosition(rig, name) {
  return rig.bones.get(name).getWorldPosition(new THREE.Vector3());
}

test('elapsed time does not shake the stretched arms or torso at a fixed progress', () => {
  const { rig, pose } = createHarness();
  const names = ['左腕', '右腕', '左ひじ', '右ひじ', '左手首', '右手首', '上半身', '下半身', '首', '頭'];
  pose(0.48, 'yawn', 0.1);
  const first = boneSnapshot(rig, names);
  pose(0.48, 'yawn', 21.7);
  const later = boneSnapshot(rig, names);
  assert.deepEqual(later, first);
});

test('hands meet above the head at the peak and return as the stretch ends', () => {
  const { rig, pose } = createHarness();
  pose(0.48);
  const head = worldPosition(rig, '頭');
  const leftPeak = worldPosition(rig, '左中指３');
  const rightPeak = worldPosition(rig, '右中指３');
  const peakGap = leftPeak.distanceTo(rightPeak);

  assert.ok(peakGap < 1.2, `peak hand gap ${peakGap}`);
  assert.ok(Math.min(leftPeak.y, rightPeak.y) > head.y + 0.8, `hands ${leftPeak.y}/${rightPeak.y}, head ${head.y}`);

  pose(1);
  const leftEnd = worldPosition(rig, '左中指３');
  const rightEnd = worldPosition(rig, '右中指３');
  assert.ok(leftEnd.y < leftPeak.y - 4 && rightEnd.y < rightPeak.y - 4, 'hands do not lower after the peak');
  assert.ok(leftEnd.distanceTo(rightEnd) > peakGap + 2, 'hands do not separate while lowering');
});

test('stretch leaves the center and ankle controls untouched', () => {
  const { rig, pose } = createHarness();
  const names = ['センター', '左足首', '右足首'];
  const inputs = pose(0.5, 'side');
  assert.deepEqual(inputs.filter(input => names.includes(input[1])), [], 'stretch drives a center or ankle control');
  for (const name of names) {
    const bone = rig.bones.get(name);
    const rest = rig.restPose.get(bone);
    assert.deepEqual(bone.position.toArray(), rest.position.toArray(), `${name} position changed`);
    assert.equal(bone.quaternion.angleTo(rest.quaternion), 0, `${name} rotation changed`);
  }
});

test('all stretch styles stay finite and continuous from start to finish', () => {
  for (const style of ['plain', 'yawn', 'side']) {
    const { rig, pose } = createHarness();
    let previous = null;
    for (let frame = 0; frame <= 300; frame += 1) {
      const inputs = pose(frame / 300, style);
      for (const input of inputs) {
        for (const value of input.slice(1)) {
          if (typeof value === 'number') assert.ok(Number.isFinite(value), `${style} produced a non-finite input`);
        }
      }
      const current = new Map(rig.allBones.map(bone => [bone.name, bone.quaternion.clone()]));
      if (previous) {
        const largestStep = Math.max(...rig.allBones.map(bone => current.get(bone.name).angleTo(previous.get(bone.name))));
        assert.ok(largestStep < 0.08, `${style} jumps ${largestStep} radians at frame ${frame}`);
      }
      previous = current;
    }
  }
});
