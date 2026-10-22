import * as THREE from './vendor/three.module.js';

const SIDE_NAMES = ['左', '右'];
const EPSILON = 1e-6;

const clamp01 = value => THREE.MathUtils.clamp(value, 0, 1);
const smoothstep = value => {
  const bounded = clamp01(value);
  return bounded * bounded * (3 - 2 * bounded);
};

function positiveModulo(value, divisor) {
  return ((value % divisor) + divisor) % divisor;
}

function leftFootSteps(u) {
  const pair = Math.floor(u / 2);
  const within = u - pair * 2;
  if (within < 1) return pair * 2 + 0.5;
  return THREE.MathUtils.lerp(pair * 2 + 0.5, pair * 2 + 2.5, smoothstep(within - 1));
}

function footSample(u, side) {
  const shifted = side === '左' ? u : u + 1;
  const within = positiveModulo(shifted, 2);
  return {
    planted: within <= 1 + EPSILON,
    swing: within < 1 ? 0 : within - 1,
    steps: side === '左' ? leftFootSteps(u) : leftFootSteps(u + 1) - 1
  };
}

function setWorldQuaternion(bone, desired, parentQuaternion, inverseParent) {
  if (bone.parent) bone.parent.getWorldQuaternion(parentQuaternion);
  else parentQuaternion.identity();
  inverseParent.copy(parentQuaternion).invert();
  bone.quaternion.copy(inverseParent.multiply(desired));
}

export function createWalking({ model, bones, restPose }) {
  const legs = Object.fromEntries(SIDE_NAMES.map(side => [side, {
    hip: bones.get(`${side}足`),
    knee: bones.get(`${side}ひざ`),
    ankle: bones.get(`${side}足首`),
    renderedAnkle: bones.get(`${side}足首D`) || bones.get(`${side}足首`),
    grants: [
      [bones.get(`${side}足`), bones.get(`${side}足D`)],
      [bones.get(`${side}ひざ`), bones.get(`${side}ひざD`)],
      [bones.get(`${side}足首`), bones.get(`${side}足首D`)]
    ].filter(([, driven]) => driven),
    groundY: 0,
    neutralY: 0,
    neutralOffsetX: 0,
    neutralOffsetZ: 0,
    neutralZ: 0,
    initialX: 0,
    z: 0,
    swingStartZ: 0,
    landingZ: 0,
    needsRebaseZ: false,
    relativeQuaternion: new THREE.Quaternion(),
    neutralQuaternion: new THREE.Quaternion(),
    currentTargetQuaternion: new THREE.Quaternion(),
    lockedQuaternion: new THREE.Quaternion(),
    swingStartQuaternion: new THREE.Quaternion(),
    wasPlanted: true,
    target: new THREE.Vector3(),
    planted: true,
    landingHome: false,
    firstSwing: false,
    swing: 0
  }]));

  let plan = null;
  let weight = 0;
  let turnWeight = 0;
  let effectiveU = 0;
  let stopping = null;
  let recovery = null;
  let initializedFeet = false;
  let lastPose = { active: false, weight: 0, direction: 1, turn: 0, stride: 0 };

  const hipPosition = new THREE.Vector3();
  const kneePosition = new THREE.Vector3();
  const anklePosition = new THREE.Vector3();
  const targetPosition = new THREE.Vector3();
  const upperDirection = new THREE.Vector3();
  const lowerDirection = new THREE.Vector3();
  const desiredDirection = new THREE.Vector3();
  const axis = new THREE.Vector3();
  const poleDirection = new THREE.Vector3();
  const desiredKnee = new THREE.Vector3();
  const currentWorldQuaternion = new THREE.Quaternion();
  const desiredWorldQuaternion = new THREE.Quaternion();
  const landingWorldQuaternion = new THREE.Quaternion();
  const deltaQuaternion = new THREE.Quaternion();
  const parentQuaternion = new THREE.Quaternion();
  const inverseParent = new THREE.Quaternion();
  const modelQuaternion = new THREE.Quaternion();
  const inverseModelQuaternion = new THREE.Quaternion();
  const restDelta = new THREE.Quaternion();
  const canonicalPosition = new THREE.Vector3();
  const canonicalOffset = new THREE.Vector3();

  const savedModelY = model.position.y;
  model.position.y = 0;
  model.updateMatrixWorld(true);
  for (const side of SIDE_NAMES) {
    const leg = legs[side];
    if (!leg.renderedAnkle) continue;
    leg.renderedAnkle.getWorldPosition(canonicalPosition);
    leg.neutralOffsetX = canonicalPosition.x - model.position.x;
    leg.neutralOffsetZ = canonicalPosition.z - model.position.z;
    leg.neutralY = canonicalPosition.y;
    leg.neutralZ = canonicalPosition.z;
    leg.renderedAnkle.getWorldQuaternion(leg.neutralQuaternion);
    leg.currentTargetQuaternion.copy(leg.neutralQuaternion);
  }
  model.position.y = savedModelY;
  model.updateMatrixWorld(true);

  function legWorldLength() {
    const leg = legs.左;
    if (!leg.hip || !leg.knee || !leg.ankle) return 9.5;
    const upper = restPose.get(leg.knee)?.position.length() || 5;
    const lower = restPose.get(leg.ankle)?.position.length() || 5;
    return (upper + lower) * model.scale.y;
  }

  function begin(rootX, destinationX, preserveFeet = false) {
    const distance = Math.abs(destinationX - rootX);
    const homeOnly = preserveFeet && distance <= 0.02;
    const nominalStep = Math.max(0.5, legWorldLength() * 0.24);
    let stepCount = Math.max(2, 2 * Math.round(distance / (2 * nominalStep)));
    if (distance / stepCount > nominalStep * 1.25) stepCount += 2;
    const stepLength = distance / stepCount;
    plan = {
      fromX: rootX,
      destinationX,
      distance,
      direction: Math.sign(destinationX - rootX) || 1,
      stepCount,
      stepLength,
      motionScale: homeOnly ? 1 : Math.min(1, stepLength / (nominalStep * 0.75)),
      turnScale: Math.min(1, distance / nominalStep),
      firstSwingSide: Math.sign(destinationX - rootX) < 0 ? '左' : '右',
      homeOnly,
      needsHome: preserveFeet
    };
    effectiveU = 0;
    stopping = null;
    if (preserveFeet) {
      for (const side of SIDE_NAMES) {
        const leg = legs[side];
        leg.initialX = leg.target.x;
        leg.z = leg.target.z;
        leg.swingStartZ = leg.z;
        leg.landingZ = leg.z;
        leg.needsRebaseZ = true;
      }
      plan.firstSwingSide = SIDE_NAMES.reduce((trailing, side) => {
        const offset = plan.direction * (legs[side].initialX - rootX);
        const trailingOffset = plan.direction * (legs[trailing].initialX - rootX);
        return offset < trailingOffset ? side : trailing;
      });
      if (homeOnly) {
        const first = SIDE_NAMES.reduce((farther, side) => {
          const distanceFromHome = Math.abs(legs[side].target.x - (rootX + legs[side].neutralOffsetX));
          const fartherDistance = Math.abs(legs[farther].target.x - (rootX + legs[farther].neutralOffsetX));
          return distanceFromHome > fartherDistance ? side : farther;
        });
        stopping = { progress: 0, rootX, order: [first, first === '左' ? '右' : '左'], starts: null };
      }
    } else {
      initializedFeet = false;
    }
  }

  function gaitSideFor(side) {
    return side === plan?.firstSwingSide ? '右' : '左';
  }

  function sampleFoot(side) {
    const gaitSide = gaitSideFor(side);
    const sample = footSample(effectiveU, gaitSide);
    const offset = gaitSide === '左' ? -0.5 : 0.5;
    const displacement = sample.steps + offset;
    const landingU = sample.planted ? effectiveU : Math.ceil(effectiveU - EPSILON);
    const landingDisplacement = footSample(landingU, gaitSide).steps + offset;
    return { ...sample, displacement, landingDisplacement };
  }

  function startRecovery(destinationX) {
    recovery = {
      destinationX,
      progress: 0,
      starts: Object.fromEntries(SIDE_NAMES.map(side => [side, legs[side].target.clone()])),
      quaternions: Object.fromEntries(SIDE_NAMES.map(side => [side, legs[side].currentTargetQuaternion.clone()]))
    };
    stopping = null;
  }

  function reset() {
    plan = null;
    weight = 0;
    turnWeight = 0;
    effectiveU = 0;
    stopping = null;
    recovery = null;
    initializedFeet = false;
    lastPose = { active: false, weight: 0, direction: 1, turn: 0, stride: 0 };
    stance.weight = 0;
    stance.captured = false;
    stance.step = null;
  }

  function update({ walking, rootX, destinationX, delta = 0 }) {
    const safeDelta = THREE.MathUtils.clamp(Number(delta) || 0, 0, 0.1);
    if (walking && Number.isFinite(rootX) && Number.isFinite(destinationX)) {
      const nextDirection = Math.sign(destinationX - rootX) || plan?.direction || 1;
      const changedDestination = plan && Math.abs(destinationX - plan.destinationX) > 0.02;
      const reversed = plan && nextDirection !== plan.direction && Math.abs(destinationX - rootX) > 0.02;
      if (!plan) begin(rootX, destinationX);
      else if ((changedDestination || reversed) && initializedFeet && !recovery) startRecovery(destinationX);
      else if (recovery) recovery.destinationX = destinationX;
      else if (changedDestination || reversed) begin(rootX, destinationX);
    }

    if (recovery) {
      recovery.progress = Math.min(1, recovery.progress + safeDelta / 0.35);
      turnWeight = Math.max(0, turnWeight - safeDelta / 0.27);
      weight = Math.max(weight, 1);
      if (recovery.progress >= 1 - EPSILON) {
        const destination = recovery.destinationX;
        recovery = null;
        begin(rootX, destination, true);
      } else {
        lastPose = {
          active: true,
          weight,
          direction: plan.direction,
          turn: turnWeight,
          stride: 0,
          phase: effectiveU
        };
        return lastPose;
      }
    }

    if (plan?.homeOnly) {
      if (stopping.progress < 2 - EPSILON) {
        stopping.progress = Math.min(2, stopping.progress + safeDelta / 0.55);
      } else if (turnWeight > EPSILON) {
        turnWeight = Math.max(0, turnWeight - safeDelta / 0.27);
      } else {
        weight = Math.max(0, weight - safeDelta / 0.27);
      }
      const settling = stopping.progress < 2 - EPSILON;
      lastPose = {
        active: settling || weight > EPSILON,
        weight,
        direction: plan.direction,
        turn: 0,
        stride: 0,
        phase: effectiveU
      };
      return lastPose;
    }

    if (!plan || plan.distance < EPSILON) {
      turnWeight = Math.max(0, turnWeight - safeDelta / 0.27);
      if (turnWeight <= EPSILON) weight = Math.max(0, weight - safeDelta / 0.27);
      lastPose = { active: weight > EPSILON, weight, direction: plan?.direction || 1, turn: turnWeight, stride: 0 };
      return lastPose;
    }

    const travel = THREE.MathUtils.clamp(plan.direction * (rootX - plan.fromX), 0, plan.distance);
    const travelU = travel / plan.stepLength;
    const arrived = travel >= plan.distance - 0.01;
    const requested = Boolean(walking) && !arrived;

    if (requested) {
      effectiveU = travelU;
      stopping = null;
      weight = Math.min(1, weight + safeDelta / 0.18);
      turnWeight = Math.min(1, turnWeight + safeDelta / 0.18);
    } else {
      if (!arrived && !stopping) {
        const samples = Object.fromEntries(SIDE_NAMES.map(side => [side, sampleFoot(side)]));
        const first = SIDE_NAMES.find(side => !samples[side].planted) || '右';
        stopping = { progress: 0, rootX, order: [first, first === '左' ? '右' : '左'], starts: null };
      } else if (arrived && !stopping) {
        const landingSide = plan.firstSwingSide === '左' ? '右' : '左';
        stopping = plan.needsHome
          ? { progress: 0, rootX, order: [landingSide, plan.firstSwingSide], starts: null }
          : { progress: 2, rootX, order: ['右', '左'], starts: null };
      }
      if (stopping && stopping.progress < 2 - EPSILON) {
        stopping.progress = Math.min(2, stopping.progress + safeDelta / 0.45);
      } else if (turnWeight > EPSILON) {
        turnWeight = Math.max(0, turnWeight - safeDelta / 0.27);
      } else {
        weight = Math.max(0, weight - safeDelta / 0.27);
      }
    }

    const settling = stopping && stopping.progress < 2 - EPSILON;
    const active = requested || Boolean(settling) || weight > EPSILON;
    const startTurn = smoothstep(effectiveU / 0.16);
    lastPose = {
      active,
      weight,
      direction: plan.direction,
      turn: turnWeight * startTurn * plan.turnScale,
      stride: stopping ? 0 : Math.sin(effectiveU * Math.PI) * weight * plan.motionScale,
      phase: effectiveU
    };
    return lastPose;
  }

  function initializeFeet() {
    model.position.y = 0;
    model.updateMatrixWorld(true);
    model.getWorldQuaternion(modelQuaternion);
    inverseModelQuaternion.copy(modelQuaternion).invert();
    for (const side of SIDE_NAMES) {
      const leg = legs[side];
      if (!leg.renderedAnkle) continue;
      leg.renderedAnkle.getWorldPosition(leg.target);
      leg.renderedAnkle.getWorldQuaternion(leg.lockedQuaternion);
      leg.relativeQuaternion.copy(inverseModelQuaternion).multiply(leg.lockedQuaternion);
      leg.currentTargetQuaternion.copy(leg.lockedQuaternion);
      leg.swingStartQuaternion.copy(leg.lockedQuaternion);
      leg.groundY = leg.neutralY + 0.35 * model.scale.y;
      leg.initialX = leg.target.x;
      leg.z = leg.target.z;
      leg.swingStartZ = leg.z;
      leg.landingZ = leg.z;
      leg.needsRebaseZ = false;
      leg.wasPlanted = true;
    }
    initializedFeet = true;
  }

  function updateFootTargets() {
    model.getWorldQuaternion(modelQuaternion);
    if (recovery) {
      const progress = smoothstep(recovery.progress);
      for (const side of SIDE_NAMES) {
        const leg = legs[side];
        const start = recovery.starts[side];
        leg.target.copy(start);
        leg.target.y = THREE.MathUtils.lerp(start.y, leg.groundY, progress);
        leg.swingStartQuaternion.copy(recovery.quaternions[side]);
        leg.wasPlanted = progress >= 1 - EPSILON || start.y <= leg.groundY + 0.01;
        leg.planted = false;
        leg.firstSwing = false;
        leg.swing = leg.wasPlanted ? 0 : recovery.progress;
      }
      return;
    }
    if (stopping) {
      if (!stopping.starts) {
        stopping.starts = Object.fromEntries(SIDE_NAMES.map(side => [side, legs[side].target.clone()]));
        stopping.quaternions = Object.fromEntries(SIDE_NAMES.map(side => [side, legs[side].currentTargetQuaternion.clone()]));
      }
      for (const side of SIDE_NAMES) {
        const leg = legs[side];
        const stage = stopping.order.indexOf(side);
        const progress = clamp01(stopping.progress - stage);
        const moving = progress > EPSILON && progress < 1 - EPSILON;
        const neutralX = stopping.rootX + leg.neutralOffsetX;
        leg.target.copy(stopping.starts[side]);
        leg.target.x = THREE.MathUtils.lerp(leg.target.x, neutralX, smoothstep(progress));
        const releaseWeight = stopping.progress >= 2 - EPSILON && turnWeight <= EPSILON ? weight : 1;
        const baselineY = THREE.MathUtils.lerp(leg.neutralY, leg.groundY, releaseWeight);
        leg.target.y = baselineY + Math.sin(progress * Math.PI) ** 2 * 0.64 * model.scale.y * plan.motionScale;
        leg.target.z = THREE.MathUtils.lerp(leg.target.z, leg.neutralZ, smoothstep(progress));
        if (progress >= 1 - EPSILON) leg.lockedQuaternion.copy(leg.neutralQuaternion);
        else if (moving) leg.swingStartQuaternion.copy(stopping.quaternions[side]);
        leg.wasPlanted = !moving;
        leg.planted = !moving && weight > 0.999;
        leg.firstSwing = false;
        leg.swing = moving ? progress : 0;
      }
      return;
    }
    for (const side of SIDE_NAMES) {
      const leg = legs[side];
      const sample = sampleFoot(side);
      const gaitSide = gaitSideFor(side);
      const firstSwingStart = gaitSide === '右' ? 0 : 1;
      const rebase = plan.needsHome ? smoothstep(effectiveU - firstSwingStart) : 0;
      const baseX = THREE.MathUtils.lerp(leg.initialX, plan.fromX + leg.neutralOffsetX, rebase);
      let targetX = baseX + plan.direction * sample.displacement * plan.stepLength;
      if (plan.needsHome && effectiveU > firstSwingStart && effectiveU < firstSwingStart + 1) {
        const firstSwing = effectiveU - firstSwingStart;
        const landingX = plan.fromX + leg.neutralOffsetX
          + plan.direction * sample.landingDisplacement * plan.stepLength;
        targetX = THREE.MathUtils.lerp(leg.initialX, landingX, firstSwing);
      }
      let targetZ = leg.z;
      if (leg.needsRebaseZ && !sample.planted) {
        if (leg.wasPlanted) leg.swingStartZ = leg.z;
        canonicalOffset.set(leg.neutralOffsetX, 0, leg.neutralOffsetZ).applyQuaternion(modelQuaternion);
        leg.landingZ = model.position.z + canonicalOffset.z;
        targetZ = THREE.MathUtils.lerp(leg.swingStartZ, leg.landingZ, smoothstep(sample.swing));
      }
      leg.landingHome = sample.landingDisplacement >= plan.stepCount - EPSILON;
      if (!leg.wasPlanted && sample.planted) {
        if (leg.needsRebaseZ) {
          canonicalOffset.set(leg.neutralOffsetX, 0, leg.neutralOffsetZ).applyQuaternion(modelQuaternion);
          leg.landingZ = model.position.z + canonicalOffset.z;
          leg.z = leg.landingZ;
          targetZ = leg.z;
          leg.needsRebaseZ = false;
        }
        if (leg.landingHome) leg.lockedQuaternion.copy(leg.neutralQuaternion);
        else leg.lockedQuaternion.copy(modelQuaternion).multiply(leg.relativeQuaternion);
      } else if (leg.wasPlanted && !sample.planted) {
        leg.swingStartQuaternion.copy(leg.lockedQuaternion);
      }
      leg.wasPlanted = sample.planted;
      leg.planted = sample.planted && weight > 0.999;
      leg.firstSwing = plan.needsHome
        && effectiveU > firstSwingStart
        && effectiveU < firstSwingStart + 1;
      leg.swing = sample.swing;
      leg.target.set(
        targetX,
        leg.groundY + Math.sin(sample.swing * Math.PI) ** 2 * 0.64 * model.scale.y * plan.motionScale,
        targetZ
      );
    }
  }

  function alignBone(bone, currentDirection, nextDirection) {
    if (currentDirection.lengthSq() < EPSILON || nextDirection.lengthSq() < EPSILON) return;
    deltaQuaternion.setFromUnitVectors(currentDirection.normalize(), nextDirection.normalize());
    bone.getWorldQuaternion(currentWorldQuaternion);
    desiredWorldQuaternion.copy(deltaQuaternion).multiply(currentWorldQuaternion);
    setWorldQuaternion(bone, desiredWorldQuaternion, parentQuaternion, inverseParent);
  }

  function solveLeg(leg) {
    if (!leg.hip || !leg.knee || !leg.ankle) return;
    model.updateMatrixWorld(true);
    leg.hip.getWorldPosition(hipPosition);
    leg.knee.getWorldPosition(kneePosition);
    leg.ankle.getWorldPosition(anklePosition);

    const constraintWeight = stopping && stopping.progress >= 2 - EPSILON && turnWeight <= EPSILON ? 1 : weight;
    targetPosition.copy(anklePosition).lerp(leg.target, constraintWeight);
    const upperLength = hipPosition.distanceTo(kneePosition);
    const lowerLength = kneePosition.distanceTo(anklePosition);
    axis.copy(targetPosition).sub(hipPosition);
    const rawDistance = axis.length();
    if (rawDistance < EPSILON) return;
    axis.multiplyScalar(1 / rawDistance);
    const distance = THREE.MathUtils.clamp(rawDistance, Math.abs(upperLength - lowerLength) + 0.001, upperLength + lowerLength - 0.004);
    const along = (upperLength * upperLength - lowerLength * lowerLength + distance * distance) / (2 * distance);
    const height = Math.sqrt(Math.max(0, upperLength * upperLength - along * along));

    poleDirection.set(0, 0, 1).applyQuaternion(modelQuaternion);
    poleDirection.addScaledVector(axis, -poleDirection.dot(axis));
    if (poleDirection.lengthSq() < 1e-5) {
      poleDirection.set(1, 0, 0).applyQuaternion(modelQuaternion);
      poleDirection.addScaledVector(axis, -poleDirection.dot(axis));
    }
    poleDirection.normalize();
    desiredKnee.copy(hipPosition).addScaledVector(axis, along).addScaledVector(poleDirection, height);

    upperDirection.copy(kneePosition).sub(hipPosition);
    desiredDirection.copy(desiredKnee).sub(hipPosition);
    alignBone(leg.hip, upperDirection, desiredDirection);
    model.updateMatrixWorld(true);

    leg.knee.getWorldPosition(kneePosition);
    leg.ankle.getWorldPosition(anklePosition);
    lowerDirection.copy(anklePosition).sub(kneePosition);
    desiredDirection.copy(targetPosition).sub(kneePosition);
    alignBone(leg.knee, lowerDirection, desiredDirection);
    model.updateMatrixWorld(true);

    leg.ankle.getWorldQuaternion(currentWorldQuaternion);
    if (leg.landingHome) landingWorldQuaternion.copy(leg.neutralQuaternion);
    else landingWorldQuaternion.copy(modelQuaternion).multiply(leg.relativeQuaternion);
    if (recovery && !leg.wasPlanted) {
      desiredWorldQuaternion.slerpQuaternions(leg.swingStartQuaternion, leg.neutralQuaternion, smoothstep(leg.swing));
    } else if (stopping && !leg.wasPlanted) {
      desiredWorldQuaternion.slerpQuaternions(leg.swingStartQuaternion, leg.neutralQuaternion, smoothstep(leg.swing));
    } else if (leg.wasPlanted) desiredWorldQuaternion.copy(leg.lockedQuaternion);
    else desiredWorldQuaternion.slerpQuaternions(
      leg.swingStartQuaternion,
      landingWorldQuaternion,
      leg.firstSwing ? leg.swing : smoothstep(leg.swing)
    );
    currentWorldQuaternion.slerp(desiredWorldQuaternion, constraintWeight);
    leg.currentTargetQuaternion.copy(currentWorldQuaternion);
    setWorldQuaternion(leg.ankle, currentWorldQuaternion, parentQuaternion, inverseParent);
  }

  function refreshLegGrants() {
    for (const side of SIDE_NAMES) {
      for (const [source, driven] of legs[side].grants) {
        const sourceRest = restPose.get(source);
        const drivenRest = restPose.get(driven);
        if (!sourceRest || !drivenRest) continue;
        driven.position.copy(drivenRest.position);
        driven.quaternion.copy(drivenRest.quaternion);
        driven.scale.copy(drivenRest.scale);
        restDelta.copy(sourceRest.quaternion).invert().multiply(source.quaternion);
        driven.quaternion.multiply(restDelta);
      }
    }
  }

  function solve() {
    if (!plan || weight <= EPSILON) return;
    model.position.y = 0;
    model.updateMatrixWorld(true);
    if (!initializedFeet) initializeFeet();
    updateFootTargets();
    for (const side of SIDE_NAMES) solveLeg(legs[side]);
    refreshLegGrants();
    model.updateMatrixWorld(true);
  }

  // ---- Standing still: feet stay where they are ---------------------------------
  //
  // Gestures sway the hips (dancing, stretching, leaning): without this the feet would slide
  // along with the body. While she stands, each foot is held at a planted spot under her
  // and the legs bend to reach it. If the body drifts or turns too far from that spot, she
  // takes a small step to re-plant (feet lifted, never dragged).
  const STANCE_SLACK = 0.45;
  const STANCE_TURN = 0.6;
  const STANCE_STEP_SECONDS = 0.32;
  const stance = {
    weight: 0,
    captured: false,
    rootX: 0,
    rootZ: 0,
    yaw: 0,
    step: null,
    targets: Object.fromEntries(SIDE_NAMES.map(side => [side, new THREE.Vector3()])),
    quaternions: Object.fromEntries(SIDE_NAMES.map(side => [side, new THREE.Quaternion()]))
  };
  const stanceEuler = new THREE.Euler();

  function stanceSpot(side, target, quaternion) {
    const leg = legs[side];
    canonicalOffset.set(leg.neutralOffsetX, 0, leg.neutralOffsetZ).applyQuaternion(modelQuaternion);
    target.set(model.position.x + canonicalOffset.x, leg.neutralY, model.position.z + canonicalOffset.z);
    quaternion.copy(modelQuaternion).multiply(leg.neutralQuaternion);
  }

  function captureStance() {
    for (const side of SIDE_NAMES) stanceSpot(side, stance.targets[side], stance.quaternions[side]);
    stance.rootX = model.position.x;
    stance.rootZ = model.position.z;
    stance.yaw = stanceEuler.setFromQuaternion(modelQuaternion, 'YXZ').y;
    stance.captured = true;
  }

  function solveLegTo(leg, target, quaternion, amount) {
    if (!leg.hip || !leg.knee || !leg.ankle || amount <= EPSILON) return;
    model.updateMatrixWorld(true);
    leg.hip.getWorldPosition(hipPosition);
    leg.knee.getWorldPosition(kneePosition);
    leg.ankle.getWorldPosition(anklePosition);
    targetPosition.copy(anklePosition).lerp(target, amount);
    const upperLength = hipPosition.distanceTo(kneePosition);
    const lowerLength = kneePosition.distanceTo(anklePosition);
    axis.copy(targetPosition).sub(hipPosition);
    const rawDistance = axis.length();
    if (rawDistance < EPSILON) return;
    axis.multiplyScalar(1 / rawDistance);
    const distance = THREE.MathUtils.clamp(rawDistance, Math.abs(upperLength - lowerLength) + 0.001, upperLength + lowerLength - 0.004);
    const along = (upperLength * upperLength - lowerLength * lowerLength + distance * distance) / (2 * distance);
    const height = Math.sqrt(Math.max(0, upperLength * upperLength - along * along));
    poleDirection.set(0, 0, 1).applyQuaternion(modelQuaternion);
    poleDirection.addScaledVector(axis, -poleDirection.dot(axis));
    if (poleDirection.lengthSq() < 1e-5) {
      poleDirection.set(1, 0, 0).applyQuaternion(modelQuaternion);
      poleDirection.addScaledVector(axis, -poleDirection.dot(axis));
    }
    poleDirection.normalize();
    desiredKnee.copy(hipPosition).addScaledVector(axis, along).addScaledVector(poleDirection, height);
    upperDirection.copy(kneePosition).sub(hipPosition);
    desiredDirection.copy(desiredKnee).sub(hipPosition);
    alignBone(leg.hip, upperDirection, desiredDirection);
    model.updateMatrixWorld(true);
    leg.knee.getWorldPosition(kneePosition);
    leg.ankle.getWorldPosition(anklePosition);
    lowerDirection.copy(anklePosition).sub(kneePosition);
    desiredDirection.copy(targetPosition).sub(kneePosition);
    alignBone(leg.knee, lowerDirection, desiredDirection);
    model.updateMatrixWorld(true);
    leg.ankle.getWorldQuaternion(currentWorldQuaternion);
    currentWorldQuaternion.slerp(quaternion, amount);
    setWorldQuaternion(leg.ankle, currentWorldQuaternion, parentQuaternion, inverseParent);
  }

  /**
   * Call every frame after the pose, instead of solve(), while she isn't walking.
   * `active` false (carried, dragged, lying, spinning…) lets the feet follow the body again.
   */
  function holdStance({ active, delta = 0, release = false }) {
    const safeDelta = THREE.MathUtils.clamp(Number(delta) || 0, 0, 0.1);
    // Picked up, dragged or lying down: the feet go with her at once.
    if (release) {
      stance.weight = 0;
      stance.captured = false;
      stance.step = null;
      return;
    }
    // Walking (or settling after a walk) owns the legs.
    if (plan && weight > EPSILON) {
      // Take over exactly where the walk left her feet (no snap when it hands over).
      model.getWorldQuaternion(modelQuaternion);
      for (const side of SIDE_NAMES) {
        const leg = legs[side];
        stance.targets[side].set(leg.target.x, leg.neutralY, leg.target.z);
        stance.quaternions[side].copy(leg.currentTargetQuaternion);
      }
      stance.rootX = model.position.x;
      stance.rootZ = model.position.z;
      stance.yaw = stanceEuler.setFromQuaternion(modelQuaternion, 'YXZ').y;
      stance.captured = initializedFeet;
      stance.step = null;
      stance.weight = 1;
      return;
    }
    stance.weight = active ? Math.min(1, stance.weight + safeDelta / 0.25) : Math.max(0, stance.weight - safeDelta / 0.2);
    if (stance.weight <= EPSILON) {
      stance.captured = false;
      stance.step = null;
      return;
    }
    model.position.y = 0;
    model.updateMatrixWorld(true);
    model.getWorldQuaternion(modelQuaternion);
    if (!stance.captured) captureStance();
    const yaw = stanceEuler.setFromQuaternion(modelQuaternion, 'YXZ').y;
    const drift = Math.hypot(model.position.x - stance.rootX, model.position.z - stance.rootZ);
    const turned = Math.abs(Math.atan2(Math.sin(yaw - stance.yaw), Math.cos(yaw - stance.yaw)));
    if (!stance.step && (drift > STANCE_SLACK || turned > STANCE_TURN)) {
      // Too far from where she planted her feet: a quick little step to re-plant them.
      stance.step = {
        progress: 0,
        from: Object.fromEntries(SIDE_NAMES.map(side => [side, stance.targets[side].clone()])),
        fromQ: Object.fromEntries(SIDE_NAMES.map(side => [side, stance.quaternions[side].clone()]))
      };
      captureStance();
    }
    for (const [index, side] of SIDE_NAMES.entries()) {
      const leg = legs[side];
      let target = stance.targets[side];
      let quaternion = stance.quaternions[side];
      if (stance.step) {
        // One foot, then the other, each lifted a little on the way.
        const local = clamp01(stance.step.progress * 2 - index);
        const eased = smoothstep(local);
        targetPosition.copy(stance.step.from[side]).lerp(stance.targets[side], eased);
        targetPosition.y += Math.sin(local * Math.PI) * 0.45 * model.scale.y;
        target = canonicalPosition.copy(targetPosition);
        quaternion = currentWorldQuaternion.copy(stance.step.fromQ[side]).slerp(stance.quaternions[side], eased).clone();
      }
      solveLegTo(leg, target.clone(), quaternion, stance.weight);
    }
    if (stance.step) {
      stance.step.progress = Math.min(1, stance.step.progress + safeDelta / STANCE_STEP_SECONDS);
      if (stance.step.progress >= 1 - EPSILON) stance.step = null;
    }
    refreshLegGrants();
    model.updateMatrixWorld(true);
  }

  function stanceStatus() {
    return {
      weight: stance.weight,
      stepping: Boolean(stance.step),
      targets: Object.fromEntries(SIDE_NAMES.map(side => [side, stance.targets[side].toArray()]))
    };
  }

  function status() {
    const feet = {};
    for (const side of SIDE_NAMES) {
      const leg = legs[side];
      feet[side] = {
        planted: leg.planted,
        swing: leg.swing,
        groundY: leg.groundY,
        targetWorld: leg.target.toArray()
      };
    }
    return {
      active: lastPose.active,
      weight,
      direction: plan?.direction || 1,
      stepCount: plan?.stepCount || 0,
      stepIndex: plan ? Math.min(plan.stepCount - 1, Math.floor(effectiveU)) : 0,
      phase: effectiveU,
      stepLength: plan?.stepLength || 0,
      recovering: Boolean(recovery),
      feet
    };
  }

  return { update, solve, reset, status, holdStance, stanceStatus };
}
