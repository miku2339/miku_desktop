import * as THREE from 'three';

const FACE_MATERIALS = new Set(['face00', 'face01', 'eye_hi', 'eye_hi2']);
const NORMAL_STEP = 0.0001;

function smoothstep(start, end, value) {
  const weight = THREE.MathUtils.clamp((value - start) / (end - start), 0, 1);
  return weight * weight * (3 - 2 * weight);
}

function bell(value, center, width) {
  const distance = (value - center) / width;
  return Math.exp(-distance * distance);
}

function deformPoint(point, features, eyeHeight) {
  const { x, y, z } = point;
  const side = Math.abs(x);
  const front = features.insideMouth ? 1 : smoothstep(0.2, 0.75, z);
  const neck = smoothstep(16.95, 17.22, y);
  const edge = 1 - smoothstep(0.92, 1.06, side);
  const forehead = 1 - smoothstep(18.72, 19.08, y);
  const support = front * neck * edge * forehead;
  const lowerFace = 1 - smoothstep(17.9, 18.08, y);
  const jaw = 1 - smoothstep(17.7, 18.05, y);
  const eye = smoothstep(17.8, 18.0, y)
    * (1 - smoothstep(18.65, 18.82, y))
    * smoothstep(0.04, 0.18, side)
    * (1 - smoothstep(0.82, 0.96, side));
  const mouth = bell(y, 17.52, 0.2) * (1 - smoothstep(0.28, 0.48, side));
  const nose = bell(x, 0, 0.14) * bell(y, 17.93, 0.16) * smoothstep(1.05, 1.25, z);

  const eyeCenter = Math.sign(x) * 0.49;
  const eyeWidth = features.iris ? 0 : (x - eyeCenter) * 0.035 * eye;
  const cheekWidth = features.iris ? 0 : x * 0.065 * jaw - x * 0.055 * mouth;
  const chin = bell(x, 0, 0.25) * (1 - smoothstep(17.28, 17.55, y));
  point.x = x + support * (cheekWidth + eyeWidth);
  point.y = y + support * (
    Math.max(0, 18.0 - y) * 0.16 * lowerFace
    + 0.035 * chin
    + (eyeHeight - y) * 0.10 * eye
    + 0.018 * smoothstep(0.55, 0.85, side) * eye
  );
  point.z = z - support * (0.055 * nose + 0.015 * mouth);
  return point;
}

export function applyFaceStyle(model) {
  const geometry = model.geometry;
  const materials = Array.isArray(model.material) ? model.material : [model.material];
  const bones = model.skeleton?.bones || [];
  const dictionary = model.morphTargetDictionary || {};
  if (geometry?.userData?.MMD?.format !== 'pmx'
    || dictionary['口角上げ'] === undefined
    || !bones.some(bone => bone.name === 'スカート_0_0')
    || geometry.userData.mikuFaceStyle) return false;

  const position = geometry.getAttribute('position');
  const normal = geometry.getAttribute('normal');
  const skinIndex = geometry.getAttribute('skinIndex');
  const skinWeight = geometry.getAttribute('skinWeight');
  if (!position || !normal || !skinIndex || !skinWeight) return false;

  const facialVertices = new Map();
  const indices = geometry.getIndex();
  if (!indices) return false;
  for (const group of geometry.groups) {
    const material = materials[group.materialIndex];
    if (!FACE_MATERIALS.has(material?.name)) continue;
    for (let offset = group.start; offset < group.start + group.count; offset += 1) {
      const index = indices.getX(offset);
      if (facialVertices.has(index)) continue;
      let irisWeight = 0;
      for (let slot = 0; slot < 4; slot += 1) {
        const bone = bones[skinIndex.array[index * skinIndex.itemSize + slot]];
        if (/^[左右]目(?:戻)?$/.test(bone?.name || '')) {
          irisWeight += skinWeight.array[index * skinWeight.itemSize + slot];
        }
      }
      facialVertices.set(index, {
        iris: irisWeight > 0.5,
        insideMouth: material.name === 'face01'
          && position.getY(index) < 17.85
          && Math.abs(position.getX(index)) < 0.5
      });
    }
  }
  if (facialVertices.size === 0) return false;

  const leftEye = bones.find(bone => bone.name === '左目');
  const rightEye = bones.find(bone => bone.name === '右目');
  model.updateMatrixWorld(true);
  const inverseModel = model.matrixWorld.clone().invert();
  const leftPosition = leftEye?.getWorldPosition(new THREE.Vector3()).applyMatrix4(inverseModel);
  const rightPosition = rightEye?.getWorldPosition(new THREE.Vector3()).applyMatrix4(inverseModel);
  const eyeHeight = leftPosition && rightPosition ? (leftPosition.y + rightPosition.y) / 2 : 18.24166;
  const original = position.array.slice();
  const point = new THREE.Vector3();
  const shifted = new THREE.Vector3();
  const columns = [new THREE.Vector3(), new THREE.Vector3(), new THREE.Vector3()];
  const jacobian = new THREE.Matrix3();
  const normalMatrix = new THREE.Matrix3();
  const transformedNormal = new THREE.Vector3();

  for (const [index, features] of facialVertices) {
    point.fromArray(original, index * 3);
    deformPoint(point, features, eyeHeight);
    position.setXYZ(index, point.x, point.y, point.z);

    for (let axis = 0; axis < 3; axis += 1) {
      shifted.fromArray(original, index * 3);
      shifted.setComponent(axis, shifted.getComponent(axis) + NORMAL_STEP);
      deformPoint(shifted, features, eyeHeight);
      columns[axis].subVectors(shifted, point).divideScalar(NORMAL_STEP);
    }
    jacobian.set(
      columns[0].x, columns[1].x, columns[2].x,
      columns[0].y, columns[1].y, columns[2].y,
      columns[0].z, columns[1].z, columns[2].z
    );
    normalMatrix.copy(jacobian).invert().transpose();
    transformedNormal.fromBufferAttribute(normal, index).applyMatrix3(normalMatrix).normalize();
    normal.setXYZ(index, transformedNormal.x, transformedNormal.y, transformedNormal.z);
  }

  // MMD targets are absolute positions; deform each endpoint with the same face mapping.
  for (const target of geometry.morphAttributes.position || []) {
    for (const [index, features] of facialVertices) {
      point.fromBufferAttribute(target, index);
      if (geometry.morphTargetsRelative) {
        shifted.fromArray(original, index * 3);
        point.add(shifted);
      }
      deformPoint(point, features, eyeHeight);
      if (geometry.morphTargetsRelative) {
        shifted.fromBufferAttribute(position, index);
        point.sub(shifted);
      }
      target.setXYZ(index, point.x, point.y, point.z);
    }
    target.needsUpdate = true;
  }

  position.needsUpdate = true;
  normal.needsUpdate = true;
  geometry.boundingBox = null;
  geometry.boundingSphere = null;
  geometry.computeBoundingSphere();
  model.boundingBox = null;
  model.boundingSphere = null;
  geometry.userData.mikuFaceStyle = { version: 1, vertices: facialVertices.size };
  return true;
}
