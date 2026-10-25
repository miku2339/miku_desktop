import assert from 'node:assert/strict';
import fs from 'node:fs';
import test from 'node:test';

import * as THREE from '../Wallpaper/companion/vendor/three.module.js';
import { Parser } from '../Wallpaper/companion/vendor/libs/mmdparser.module.js';
import { createProps } from '../Wallpaper/companion/props.js';

const modelPath = new URL('../Wallpaper/assets/companion-model/tda/miku.pmx', import.meta.url);
const companionSource = fs.readFileSync(new URL('../Wallpaper/companion/companion.js', import.meta.url), 'utf8');

function objectLiteral(name) {
  const start = companionSource.indexOf(`const ${name} =`);
  assert.notEqual(start, -1, `${name} must exist`);
  const open = companionSource.indexOf('{', start);
  let depth = 0;
  for (let index = open; index < companionSource.length; index += 1) {
    if (companionSource[index] === '{') depth += 1;
    else if (companionSource[index] === '}') depth -= 1;
    if (depth === 0) return Function(`return (${companionSource.slice(open, index + 1)})`)();
  }
  throw new Error(`Could not extract ${name}`);
}

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
  model.scale.setScalar(0.93);
  const bones = new Map(allBones.map(bone => [bone.name, bone]));
  const restPose = new Map(allBones.map(bone => [bone, {
    position: bone.position.clone(), quaternion: bone.quaternion.clone(), scale: bone.scale.clone()
  }]));
  return { model, bones, parsed, restPose };
}

function rotateBone(rig, name, values) {
  const bone = rig.bones.get(name);
  if (bone) bone.quaternion.multiply(new THREE.Quaternion().setFromEuler(new THREE.Euler(...values, 'XYZ')));
}

function twistBone(rig, name, childName, angle) {
  const bone = rig.bones.get(name);
  const child = rig.bones.get(childName);
  const childRest = rig.restPose.get(child);
  if (!bone || !child || !childRest) return;
  const axis = childRest.position.clone();
  let parent = child.parent;
  while (parent && parent !== bone) {
    const rest = rig.restPose.get(parent);
    if (!rest) return;
    axis.multiply(rest.scale).applyQuaternion(rest.quaternion).add(rest.position);
    parent = parent.parent;
  }
  if (parent === bone) bone.quaternion.multiply(new THREE.Quaternion().setFromAxisAngle(axis.normalize(), angle));
}

function posedUmbrellaRig({ stride = 0, yaw = 0 } = {}) {
  const rig = loadRig();
  rotateBone(rig, '右腕', [-0.03 + 0.16 * stride, 0, 0.5]);
  rotateBone(rig, '右ひじ', [-0.04, -0.02, -0.12]);
  rotateBone(rig, '右手首', [-0.03, 0, 0.06]);
  const pose = objectLiteral('HOLD_POSES').umbrella;
  for (const [name, values] of Object.entries(pose)) rotateBone(rig, name, values);
  twistBone(rig, '右ひじ', '右手首', objectLiteral('HOLD_TWIST').umbrella);
  rig.model.rotation.y = yaw;
  rig.model.updateMatrixWorld(true);
  return rig;
}

function fistFrame(rig) {
  const at = name => rig.bones.get(`右${name}`).getWorldPosition(new THREE.Vector3());
  const index = at('人指１');
  const pinky = at('小指１');
  const middle = at('中指１');
  const middleTip = at('中指３');
  const wrist = at('手首');
  const axis = index.sub(pinky).normalize();
  const along = middle.clone().sub(wrist).addScaledVector(axis, -middle.clone().sub(wrist).dot(axis)).normalize();
  const inward = new THREE.Vector3().crossVectors(axis, along).normalize();
  if (middleTip.sub(middle).dot(inward) < 0) inward.negate();
  const center = wrist.clone().lerp(middle, 0.85).addScaledVector(inward, 0.14);
  return { axis, center };
}

function worldBoxCorners(root) {
  const points = [];
  root.traverse(child => {
    const geometry = child.isMesh && child.geometry;
    if (!geometry) return;
    if (!geometry.boundingBox) geometry.computeBoundingBox();
    for (const x of [geometry.boundingBox.min.x, geometry.boundingBox.max.x]) {
      for (const y of [geometry.boundingBox.min.y, geometry.boundingBox.max.y]) {
        for (const z of [geometry.boundingBox.min.z, geometry.boundingBox.max.z]) {
          points.push(new THREE.Vector3(x, y, z).applyMatrix4(child.matrixWorld));
        }
      }
    }
  });
  return points;
}

function canopyFit() {
  return Function(
    'THREE', 'PROP_FIT', 'umbrellaFitVectors',
    `${sourceFor('umbrellaCanopyLength')}; return umbrellaCanopyLength;`
  )(THREE, objectLiteral('PROP_FIT'), { offset: new THREE.Vector3() });
}

test('umbrella pose keeps its shaft upright and outside Miku on the right', () => {
  const rig = posedUmbrellaRig();
  const fist = fistFrame(rig);
  const head = rig.bones.get('頭').getWorldPosition(new THREE.Vector3());
  assert.ok(fist.axis.y > 0.82, `shaft points upward (axis ${fist.axis.toArray()}, grip ${fist.center.toArray()}, head ${head.toArray()})`);
  assert.ok(fist.axis.x > 0, `shaft leans towards her head (${fist.axis.toArray()})`);
  assert.ok(fist.center.x < head.x - 2.8, `grip stays to her right (${fist.center.x})`);
  assert.ok(fist.center.z > head.z + 0.35, `grip stays in front of her body (${fist.center.z})`);
});

test('walking and three-quarter turns keep the shaft on the same safe side', () => {
  for (const yaw of [-1.05, 0, 1.05]) {
    let previousAxis = null;
    for (const stride of [-1, 0, 1]) {
      const rig = posedUmbrellaRig({ stride, yaw });
      const fist = fistFrame(rig);
      const head = rig.bones.get('頭').getWorldPosition(new THREE.Vector3());
      const root = fist.center.clone().addScaledVector(fist.axis, -objectLiteral('PROP_FIT').umbrellaGrip);
      const atHeadHeight = root.clone().addScaledVector(fist.axis, (head.y - root.y) / fist.axis.y);
      const bodyClearance = Math.hypot(atHeadHeight.x - head.x, atHeadHeight.z - head.z);
      const toHead = head.clone().sub(root);
      const canopyOffset = Math.sqrt(Math.max(0, toHead.lengthSq() - toHead.dot(fist.axis) ** 2));
      assert.ok(fist.axis.y > 0.82, `shaft remains upright at stride ${stride}, yaw ${yaw}: ${fist.axis.toArray()}`);
      assert.ok(bodyClearance > 2.3, `shaft clears head and hair at stride ${stride}, yaw ${yaw}`);
      assert.ok(
        canopyOffset < objectLiteral('PROP_FIT').umbrellaCanopyRadius * 0.72,
        `head remains within the canopy projection at stride ${stride}, yaw ${yaw}`
      );
      if (previousAxis) assert.ok(previousAxis.dot(fist.axis) > 0.97, 'walking never flips the umbrella');
      previousAxis = fist.axis.clone();
    }
  }
});

test('minimum canopy clears the actual TDA crown hair vertex', () => {
  const rig = posedUmbrellaRig();
  const fist = fistFrame(rig);
  const constants = objectLiteral('PROP_FIT');
  const root = fist.center.clone().addScaledVector(fist.axis, -constants.umbrellaGrip);
  const hair = new THREE.Vector3().fromArray(rig.parsed.vertices[12721].position).multiplyScalar(0.93);
  const offset = hair.sub(root);
  const along = offset.dot(fist.axis);
  const radial = Math.sqrt(Math.max(0, offset.lengthSq() - along * along));
  const drop = constants.umbrellaCanopyDepth * Math.pow(
    Math.min(1, radial / constants.umbrellaCanopyRadius),
    1.48
  );
  assert.ok(radial < constants.umbrellaCanopyRadius, 'the TDA hair crown stays inside the canopy projection');
  assert.ok(constants.umbrellaLength - drop > along + 0.1, 'the minimum canopy surface clears TDA hair00 vertex 12721');
});

test('umbrella length clears the visible witch hat without disconnecting its canopy', () => {
  const rig = posedUmbrellaRig();
  const fist = fistFrame(rig);
  const props = createProps(THREE);
  const placement = objectLiteral('HAT_PLACEMENT').witch;
  props.wearHat('witch', rig.bones.get('頭'), placement);
  rig.model.updateMatrixWorld(true);

  const umbrella = props.hand.umbrella;
  umbrella.position.copy(fist.center).addScaledVector(fist.axis, -objectLiteral('PROP_FIT').umbrellaGrip);
  umbrella.quaternion.setFromUnitVectors(new THREE.Vector3(0, 1, 0), fist.axis);

  const fit = canopyFit();
  let hatTopVertex = new THREE.Vector3(0, -Infinity, 0);
  props.hats.witch.traverse(child => {
    const positions = child.isMesh && child.geometry?.getAttribute('position');
    if (!positions) return;
    for (let index = 0; index < positions.count; index += 1) {
      const point = new THREE.Vector3().fromBufferAttribute(positions, index).applyMatrix4(child.matrixWorld);
      if (point.y > hatTopVertex.y) hatTopVertex = point;
    }
  });
  const obstruction = hatTopVertex;
  const length = fit(umbrella.position, fist.axis, obstruction, umbrella.userData);
  const apex = umbrella.position.clone().addScaledVector(fist.axis, length);
  const canopyDepth = umbrella.userData.canopyDepth ?? objectLiteral('PROP_FIT').umbrellaCanopyDepth;
  const canopyRadius = umbrella.userData.canopyRadius ?? objectLiteral('PROP_FIT').umbrellaCanopyRadius;
  const offset = obstruction.clone().sub(umbrella.position);
  const along = offset.dot(fist.axis);
  const radial = Math.sqrt(offset.lengthSq() - along * along);
  const canopyDrop = canopyDepth * Math.pow(Math.min(1, radial / canopyRadius), 1.48);

  assert.ok(length - canopyDrop > along + 0.15, 'the canopy surface clears the hat top');
  assert.ok(length > objectLiteral('PROP_FIT').umbrellaLength, 'the shaft extends to the raised canopy');
  assert.ok(apex.y < 24.5, 'the fitted canopy remains within the normal wallpaper framing');

  umbrella.userData.shaft.scale.y = length;
  umbrella.userData.shaft.position.y = length / 2;
  umbrella.userData.canopyHolder.position.y = length;
  umbrella.userData.canopyHolder.quaternion.identity();
  umbrella.updateMatrixWorld(true);
  const connected = umbrella.userData.canopyHolder.getWorldPosition(new THREE.Vector3());
  assert.ok(connected.distanceTo(apex) < 1e-6, 'the canopy stays attached to the shaft endpoint');

  const localHatTop = umbrella.worldToLocal(hatTopVertex.clone());
  const localDrop = canopyDepth * Math.pow(
    Math.min(1, Math.hypot(localHatTop.x, localHatTop.z) / canopyRadius),
    1.48
  );
  const localHead = umbrella.worldToLocal(
    rig.bones.get('頭').getWorldPosition(new THREE.Vector3()).add(new THREE.Vector3(0, 1.6, 0))
  );
  assert.ok(
    Math.hypot(localHead.x, localHead.z) < canopyRadius * 0.65,
    'Miku head remains within the effective canopy projection'
  );
  assert.ok(localHatTop.y < length - localDrop - 0.1, 'the actual witch-hat tip clears the vinyl panel');
});

test('tilted Santa hat stays below the canopy support envelope', () => {
  const rig = posedUmbrellaRig();
  const fist = fistFrame(rig);
  const props = createProps(THREE);
  const umbrella = props.hand.umbrella;
  const fit = canopyFit();
  const constants = objectLiteral('PROP_FIT');
  const depth = umbrella.userData.canopyDepth ?? constants.umbrellaCanopyDepth;
  const radius = umbrella.userData.canopyRadius ?? constants.umbrellaCanopyRadius;
  props.wearHat('santa', rig.bones.get('頭'), objectLiteral('HAT_PLACEMENT').santa);
  umbrella.position.copy(fist.center).addScaledVector(fist.axis, -constants.umbrellaGrip);
  umbrella.quaternion.setFromUnitVectors(new THREE.Vector3(0, 1, 0), fist.axis);

  for (const [pitch, yaw, roll] of [[0, 0, 0], [0.18, -0.12, 0.2], [-0.16, 0.14, -0.22]]) {
    rig.bones.get('頭').rotation.set(pitch, yaw, roll);
    rig.model.updateMatrixWorld(true);
    let length = constants.umbrellaLength;
    for (const point of worldBoxCorners(props.hats.santa)) {
      length = Math.max(length, fit(umbrella.position, fist.axis, point, umbrella.userData));
    }
    umbrella.userData.canopyHolder.position.y = length;
    umbrella.userData.canopyHolder.quaternion.identity();
    umbrella.updateMatrixWorld(true);

    props.hats.santa.traverse(child => {
      const positions = child.isMesh && child.geometry?.getAttribute('position');
      if (!positions) return;
      for (let index = 0; index < positions.count; index += 1) {
        const world = new THREE.Vector3().fromBufferAttribute(positions, index).applyMatrix4(child.matrixWorld);
        const local = umbrella.worldToLocal(world);
        const drop = depth * Math.pow(Math.min(1, Math.hypot(local.x, local.z) / radius), 1.48);
        assert.ok(local.y < length - drop, `Santa hat clears at head rotation ${pitch},${yaw},${roll}`);
      }
    });
  }
});
