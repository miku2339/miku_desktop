import * as THREE from 'three';

const vertexShader = `
varying vec2 vUv;
void main() {
  vUv = uv;
  gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0);
}`;

const fragmentShader = `
uniform float opacity;
varying vec2 vUv;
void main() {
  vec2 point = (vUv - 0.5) * 2.0;
  float radius = length(point);
  float alpha = exp(-dot(point, point) * 3.8) * (1.0 - smoothstep(0.55, 1.0, radius));
  gl_FragColor = vec4(0.02, 0.04, 0.055, alpha * opacity);
}`;

export function createGrounding(scene) {
  const geometry = new THREE.PlaneGeometry(1, 1);
  const shadows = [0, 1].map(() => {
    const material = new THREE.ShaderMaterial({
      uniforms: { opacity: { value: 0 } },
      vertexShader,
      fragmentShader,
      transparent: true,
      depthWrite: false,
      toneMapped: false
    });
    const shadow = new THREE.Mesh(geometry, material);
    shadow.visible = false;
    shadow.frustumCulled = false;
    scene.add(shadow);
    return shadow;
  });
  const point = new THREE.Vector3();
  const feet = [0, 1].map(() => ({ samples: [], minY: Infinity, minX: Infinity, maxX: -Infinity, centerX: 0 }));
  let model = null;
  let lastGroundY = null;
  let lowestSoleY = null;
  let soleGaps = [null, null];

  function attach(nextModel) {
    model = nextModel;
    lastGroundY = null;
    lowestSoleY = null;
    soleGaps = [null, null];
    for (const foot of feet) foot.samples = [];
    for (const shadow of shadows) shadow.visible = false;
    const position = model?.geometry?.getAttribute('position');
    const skinIndex = model?.geometry?.getAttribute('skinIndex');
    const skinWeight = model?.geometry?.getAttribute('skinWeight');
    if (!position || !skinIndex || !skinWeight || !model.skeleton || !model.getVertexPosition) return false;

    const footBones = model.skeleton.bones.map(bone => {
      if (!/足首|足先|つま先/.test(bone.name) || /ＩＫ|IK/.test(bone.name)) return -1;
      if (bone.name.startsWith('左')) return 0;
      if (bone.name.startsWith('右')) return 1;
      return -1;
    });
    const candidates = [[], []];
    const floor = [Infinity, Infinity];
    for (let index = 0; index < position.count; index += 1) {
      const weights = [0, 0];
      for (let component = 0; component < skinIndex.itemSize; component += 1) {
        const side = footBones[skinIndex.getComponent(index, component)];
        if (side >= 0) weights[side] += skinWeight.getComponent(index, component);
      }
      for (let side = 0; side < 2; side += 1) {
        if (weights[side] < 0.5) continue;
        candidates[side].push(index);
        floor[side] = Math.min(floor[side], position.getY(index));
      }
    }
    for (let side = 0; side < 2; side += 1) {
      feet[side].samples = candidates[side].filter(index => position.getY(index) <= floor[side] + 0.1);
    }
    return feet.some(foot => foot.samples.length > 0);
  }

  function update(groundY, opacity, elevation = 0) {
    if (!model || !Number.isFinite(groundY) || !feet.some(foot => foot.samples.length > 0)) return;
    // Sample the soles after the pose, then move the body once; raised feet keep their relative height.
    model.position.y = 0;
    model.updateMatrixWorld(true);
    let floorY = Infinity;
    for (const foot of feet) {
      foot.minY = Infinity;
      foot.minX = Infinity;
      foot.maxX = -Infinity;
      foot.centerX = 0;
      for (const index of foot.samples) {
        model.getVertexPosition(index, point).applyMatrix4(model.matrixWorld);
        foot.minY = Math.min(foot.minY, point.y);
        foot.minX = Math.min(foot.minX, point.x);
        foot.maxX = Math.max(foot.maxX, point.x);
        foot.centerX += point.x;
      }
      floorY = Math.min(floorY, foot.minY);
    }
    if (!Number.isFinite(floorY)) return;
    const lift = Number.isFinite(elevation) ? Math.max(0, elevation) : 0;
    model.position.y = groundY - floorY + lift;
    model.updateMatrixWorld(true);
    lastGroundY = groundY;
    lowestSoleY = Infinity;
    for (const foot of feet) {
      foot.minY = Infinity;
      for (const index of foot.samples) {
        model.getVertexPosition(index, point).applyMatrix4(model.matrixWorld);
        foot.minY = Math.min(foot.minY, point.y);
      }
      lowestSoleY = Math.min(lowestSoleY, foot.minY);
    }
    soleGaps = feet.map(foot => Number.isFinite(foot.minY) ? Math.max(0, foot.minY - groundY) : null);
    for (let side = 0; side < 2; side += 1) {
      const foot = feet[side];
      const shadow = shadows[side];
      shadow.visible = foot.samples.length > 0;
      if (!shadow.visible) continue;
      const gap = soleGaps[side];
      const contact = 1 - THREE.MathUtils.smoothstep(gap, 0.1, 0.35);
      const airborne = lift > 0 ? 0.22 * Math.exp(-lift * 0.22) : 0;
      shadow.material.uniforms.opacity.value = THREE.MathUtils.clamp(Number.isFinite(opacity) ? opacity : 0, 0, 1)
        * (contact + airborne * (1 - contact));
      shadow.position.set(foot.centerX / foot.samples.length, groundY - 0.025, -4);
      shadow.scale.set(THREE.MathUtils.clamp((foot.maxX - foot.minX) * 1.7 + 0.35, 1.1, 2.8) + lift * 0.16, 0.45 + lift * 0.07, 1);
    }
  }

  function dispose() {
    for (const shadow of shadows) {
      shadow.removeFromParent();
      shadow.material.dispose();
    }
    geometry.dispose();
    model = null;
  }

  function status() {
    return { groundY: lastGroundY, lowestSoleY, soleGaps: [...soleGaps], sampleCounts: feet.map(foot => foot.samples.length) };
  }

  return { attach, update, dispose, status };
}
