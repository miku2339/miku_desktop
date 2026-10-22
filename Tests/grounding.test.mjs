import assert from 'node:assert/strict';
import fs from 'node:fs';
import test from 'node:test';

import * as THREE from '../Wallpaper/companion/vendor/three.module.js';

const source = fs.readFileSync(new URL('../Wallpaper/companion/grounding.js', import.meta.url), 'utf8');
const vendor = new URL('../Wallpaper/companion/vendor/three.module.js', import.meta.url).href;
const { createGrounding } = await import(`data:text/javascript,${encodeURIComponent(source.replace("from 'three'", `from '${vendor}'`))}`);

function createFeet() {
  const geometry = new THREE.BufferGeometry();
  geometry.setAttribute('position', new THREE.Float32BufferAttribute([
    -0.8, 0, 0, -0.4, 0, 0, 0.4, 0, 0, 0.8, 0, 0
  ], 3));
  geometry.setAttribute('skinIndex', new THREE.Uint16BufferAttribute([
    0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0
  ], 4));
  geometry.setAttribute('skinWeight', new THREE.Float32BufferAttribute([
    1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0
  ], 4));
  const mesh = new THREE.SkinnedMesh(geometry, new THREE.MeshBasicMaterial());
  const bones = ['左足首', '右足首'].map(name => {
    const bone = new THREE.Bone();
    bone.name = name;
    mesh.add(bone);
    return bone;
  });
  mesh.bind(new THREE.Skeleton(bones));
  const scene = new THREE.Scene();
  scene.add(mesh);
  const grounding = createGrounding(scene);
  assert.equal(grounding.attach(mesh), true);
  return { mesh, scene, grounding };
}

test('carried soles rise above the ground while their shadows stay on the floor', () => {
  const { mesh, scene, grounding } = createFeet();
  grounding.update(-2, 0.3, 4);
  assert.ok(Math.abs(grounding.status().lowestSoleY - 2) < 1e-6);
  assert.deepEqual(grounding.status().soleGaps, [4, 4]);
  const shadows = scene.children.filter(child => child !== mesh);
  assert.ok(shadows.every(shadow => Math.abs(shadow.position.y + 2.025) < 1e-6));
  assert.ok(shadows.every(shadow => shadow.material.uniforms.opacity.value > 0));
  grounding.update(-2, 0.3, 0);
  assert.ok(Math.abs(grounding.status().lowestSoleY + 2) < 1e-6);
  assert.deepEqual(grounding.status().soleGaps, [0, 0]);
});

test('invalid or negative carrying height never sinks the model below the floor', () => {
  const { grounding } = createFeet();
  for (const height of [-4, NaN, Infinity, undefined]) {
    grounding.update(-2, 0.3, height);
    assert.ok(Math.abs(grounding.status().lowestSoleY + 2) < 1e-6);
  }
});

test('standing fallback discards the previous bed height without foot samples', () => {
  const scene = new THREE.Scene();
  const mesh = new THREE.Mesh(new THREE.BufferGeometry(), new THREE.MeshBasicMaterial());
  scene.add(mesh);
  const grounding = createGrounding(scene);
  assert.equal(grounding.attach(mesh), false);
  mesh.position.y = 6;
  grounding.update(-2, 0.3, 0);
  assert.equal(mesh.position.y, 0);
});
