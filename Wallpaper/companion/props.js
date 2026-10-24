// Little things Miku holds or wears: an umbrella in the rain, an afternoon drink, a leek to
// twirl, festival hats, a summer-festival fan and Magical Mirai glowsticks.
//
// Everything is built from simple shapes with toon materials so it matches the model's look
// (the outline pass draws them too). Hand-held props are placed in world space every frame
// from her hand bones; hats are children of the head bone so they follow every nod.
// None of them take part in hit-testing: touching her still means touching her.

export const PROP_NAMES = ['umbrella', 'closedUmbrella', 'drink', 'leek', 'fan', 'glowsticks'];
export const HAT_NAMES = ['santa', 'witch', 'party', 'beanie'];

const TEAL = 0x39c5bb;

function noRaycast(object) {
  object.traverse((child) => {
    if (child.isMesh) {
      child.raycast = () => {};
      child.castShadow = false;
      child.receiveShadow = false;
      child.frustumCulled = false;
    }
  });
  return object;
}

export function createProps(THREE) {
  const toon = (color, extra = {}) => new THREE.MeshToonMaterial({ color, ...extra });
  const mesh = (geometry, material) => new THREE.Mesh(geometry, material);

  // ---- Umbrella -------------------------------------------------------------
  // Root at the hand, +Y along the shaft. The canopy sits at y = length (set every frame).
  function buildUmbrella() {
    // A clear vinyl umbrella (ビニール傘), the kind most people in Tokyo carry: see-through
    // with a faint blue tint, white ribs and rim, a shiny surface that catches the light.
    const root = new THREE.Group();
    const radius = 5.4;
    const squash = 0.62;
    const arc = Math.PI * 0.36;
    const noOutline = (material) => {
      material.userData.outlineParameters = { visible: false };
      return material;
    };
    const film = noOutline(new THREE.MeshPhongMaterial({
      color: 0xe6f4ff,
      specular: 0xffffff,
      shininess: 120,
      transparent: true,
      opacity: 0.22,
      side: THREE.DoubleSide,
      depthWrite: false
    }));
    const canopy = mesh(new THREE.SphereGeometry(radius, 32, 10, 0, Math.PI * 2, 0, arc), film);
    canopy.scale.set(1, squash, 1);
    canopy.renderOrder = 2;
    const canopyHolder = new THREE.Group();
    canopyHolder.add(canopy);
    canopy.position.y = -radius * squash;

    // Ribs along the canopy and the white rim tape.
    const rib = noOutline(new THREE.MeshPhongMaterial({ color: 0xf4f7fa, specular: 0xffffff, shininess: 60 }));
    for (let i = 0; i < 8; i += 1) {
      const angle = (i / 8) * Math.PI * 2;
      const points = [];
      for (let k = 0; k <= 10; k += 1) {
        const theta = (k / 10) * arc;
        points.push(new THREE.Vector3(
          Math.sin(theta) * Math.cos(angle) * radius,
          Math.cos(theta) * radius * squash - radius * squash,
          Math.sin(theta) * Math.sin(angle) * radius
        ));
      }
      const tube = mesh(new THREE.TubeGeometry(new THREE.CatmullRomCurve3(points), 12, 0.035, 5, false), rib);
      canopyHolder.add(tube);
      // A small white cap on each rib end.
      const end = mesh(new THREE.SphereGeometry(0.07, 6, 4), rib);
      end.position.copy(points[points.length - 1]);
      canopyHolder.add(end);
    }
    const rimHeight = Math.cos(arc) * radius * squash - radius * squash;
    const rim = mesh(new THREE.TorusGeometry(Math.sin(arc) * radius, 0.05, 4, 48), noOutline(new THREE.MeshPhongMaterial({
      color: 0xffffff, transparent: true, opacity: 0.75, shininess: 80
    })));
    rim.rotation.x = Math.PI / 2;
    rim.position.y = rimHeight;
    canopyHolder.add(rim);
    // A soft glint on the film where the light hits it.
    const glint = mesh(new THREE.SphereGeometry(radius * 1.002, 24, 6, Math.PI * 0.15, Math.PI * 0.35, arc * 0.25, arc * 0.45), noOutline(new THREE.MeshBasicMaterial({
      color: 0xffffff, transparent: true, opacity: 0.16, side: THREE.DoubleSide, depthWrite: false
    })));
    glint.scale.set(1, squash, 1);
    glint.position.y = -radius * squash;
    glint.renderOrder = 3;
    canopyHolder.add(glint);
    const tip = mesh(new THREE.CylinderGeometry(0.05, 0.08, 0.6, 8), toon(0xf4f7fa));
    tip.position.y = 0.25;
    canopyHolder.add(tip);
    root.add(canopyHolder);

    const shaft = mesh(new THREE.CylinderGeometry(0.07, 0.07, 1, 8), new THREE.MeshPhongMaterial({ color: 0xc9d2d8, specular: 0xffffff, shininess: 90 }));
    shaft.position.y = 0.5;
    root.add(shaft);
    // White plastic J handle.
    const handleMaterial = new THREE.MeshPhongMaterial({ color: 0xf2f4f6, specular: 0xffffff, shininess: 70 });
    const handle = mesh(new THREE.TorusGeometry(0.42, 0.11, 6, 14, Math.PI), handleMaterial);
    handle.position.set(0.42, -0.55, 0);
    handle.rotation.z = Math.PI;
    const grip = mesh(new THREE.CylinderGeometry(0.12, 0.12, 0.9, 8), handleMaterial);
    grip.position.y = -0.15;
    root.add(handle, grip);
    root.userData = { canopyHolder, shaft };
    return root;
  }

  // ---- The same umbrella, closed, hanging from her hand (indoors on a rainy day) ----
  // Root at the centre of the J hook; +Y up, the hook loops round +Z (her knuckle line).
  function buildClosedUmbrella() {
    const root = new THREE.Group();
    const handleMaterial = new THREE.MeshPhongMaterial({ color: 0xf2f4f6, specular: 0xffffff, shininess: 70 });
    const hookRadius = 0.2;
    const hook = mesh(new THREE.TorusGeometry(hookRadius, 0.07, 6, 14, Math.PI), handleMaterial);
    root.add(hook);
    const grip = mesh(new THREE.CylinderGeometry(0.08, 0.08, 0.7, 8), handleMaterial);
    grip.position.set(hookRadius, -0.35, 0);
    root.add(grip);
    const length = 7.6;
    const shaft = mesh(new THREE.CylinderGeometry(0.05, 0.05, length, 8), new THREE.MeshPhongMaterial({ color: 0xc9d2d8, specular: 0xffffff, shininess: 90 }));
    shaft.position.set(hookRadius, -0.7 - length / 2, 0);
    root.add(shaft);
    // The folded film: a slim, slightly crumpled cone round the lower part of the shaft.
    const film = new THREE.MeshPhongMaterial({
      color: 0xd8e9f5, specular: 0xffffff, shininess: 100, transparent: true, opacity: 0.8, depthWrite: false, side: THREE.DoubleSide
    });
    film.userData.outlineParameters = { visible: false };
    const folded = mesh(new THREE.CylinderGeometry(0.36, 0.07, 5.2, 8, 1, true), film);
    folded.position.set(hookRadius, -0.7 - length + 0.5 + 2.6 + 0.15, 0);
    folded.rotation.y = 0.3;
    root.add(folded);
    const strap = mesh(new THREE.CylinderGeometry(0.31, 0.31, 0.12, 10, 1, true), new THREE.MeshPhongMaterial({ color: 0xffffff, side: THREE.DoubleSide }));
    strap.position.set(hookRadius, folded.position.y + 0.9, 0);
    root.add(strap);
    const tip = mesh(new THREE.CylinderGeometry(0.03, 0.05, 0.5, 6), handleMaterial);
    tip.position.set(hookRadius, -0.7 - length - 0.2, 0);
    root.add(tip);
    return root;
  }

  // ---- Drink: a bubble tea with a teal straw ----------------------------------
  function buildDrink() {
    const root = new THREE.Group();
    const cup = mesh(new THREE.CylinderGeometry(0.58, 0.46, 1.7, 14), toon(0xe8cfae, { transparent: true, opacity: 0.95 }));
    cup.position.y = 0.55;
    const pearls = mesh(new THREE.CylinderGeometry(0.47, 0.45, 0.35, 14), toon(0x3a2418));
    pearls.position.y = -0.1;
    const lid = mesh(new THREE.CylinderGeometry(0.62, 0.6, 0.12, 14), toon(0xffffff));
    lid.position.y = 1.44;
    const straw = mesh(new THREE.CylinderGeometry(0.07, 0.07, 1.6, 6), toon(TEAL));
    straw.position.set(0.12, 2.0, 0);
    straw.rotation.z = -0.18;
    const sleeve = mesh(new THREE.CylinderGeometry(0.6, 0.53, 0.5, 14), toon(0xff7aa8));
    sleeve.position.y = 0.55;
    root.add(cup, pearls, lid, straw, sleeve);
    // Sized to her hand (the model's hands are small): about a cup radius of 0.3.
    root.scale.setScalar(0.52);
    return root;
  }

  // ---- Leek: white stalk, green leaves. Root at the grip; +Y towards the leaves. --
  function buildLeek() {
    const root = new THREE.Group();
    const white = mesh(new THREE.CylinderGeometry(0.23, 0.26, 2.6, 10), toon(0xf6f7ee));
    white.position.y = -0.2;
    // A flat root plate with a little tuft of short roots, like a real negi.
    const plate = mesh(new THREE.CylinderGeometry(0.25, 0.24, 0.08, 10), toon(0xd8cfa6));
    plate.position.y = -1.54;
    root.add(plate);
    const rootMaterial = toon(0xe6dcc0);
    // Too thin for an ink outline: it would turn them into black lines.
    rootMaterial.userData.outlineParameters = { visible: false };
    for (let i = 0; i < 9; i += 1) {
      const angle = (i / 9) * Math.PI * 2;
      const length = 0.16 + (i % 3) * 0.05;
      const hair = mesh(new THREE.CylinderGeometry(0.012, 0.018, length, 4), rootMaterial);
      hair.geometry.translate(0, -length / 2, 0);
      hair.position.set(Math.cos(angle) * 0.13, -1.57, Math.sin(angle) * 0.13);
      hair.rotation.set(Math.sin(angle) * 0.5, 0, -Math.cos(angle) * 0.5);
      root.add(hair);
    }
    const pale = mesh(new THREE.CylinderGeometry(0.22, 0.23, 0.6, 10), toon(0xc8e6a0));
    pale.position.y = 1.4;
    root.add(white, pale);
    const leafMaterial = toon(0x3e9e4a);
    for (const [angle, length] of [[0.22, 2.4], [-0.3, 2.0], [0.05, 2.7]]) {
      const leaf = mesh(new THREE.CylinderGeometry(0.06, 0.16, length, 8), leafMaterial);
      leaf.geometry.translate(0, length / 2, 0);
      leaf.position.y = 1.6;
      leaf.rotation.z = angle;
      leaf.rotation.y = angle * 4;
      root.add(leaf);
    }
    // Long but slim enough for her small hand to close round.
    root.scale.set(0.8, 1.25, 0.8);
    return root;
  }

  // ---- Uchiwa fan for the summer festival ---------------------------------------
  function buildFan() {
    const root = new THREE.Group();
    const face = mesh(new THREE.CircleGeometry(1.15, 24), toon(TEAL, { side: THREE.DoubleSide }));
    face.position.y = 1.55;
    const flower = mesh(new THREE.CircleGeometry(0.42, 5), toon(0xff7aa8, { side: THREE.DoubleSide }));
    flower.position.set(0.3, 1.75, 0.01);
    const flowerBack = flower.clone();
    flowerBack.position.z = -0.01;
    const center = mesh(new THREE.CircleGeometry(0.14, 12), toon(0xfff2a8, { side: THREE.DoubleSide }));
    center.position.set(0.3, 1.75, 0.02);
    const handle = mesh(new THREE.CylinderGeometry(0.07, 0.08, 1.2, 6), toon(0xc9a46a));
    handle.position.y = 0.1;
    root.add(face, flower, flowerBack, center, handle);
    return root;
  }

  // ---- Glowsticks (one per hand) --------------------------------------------------
  function buildGlowstick() {
    const root = new THREE.Group();
    const light = mesh(new THREE.CylinderGeometry(0.13, 0.13, 2.3, 10), new THREE.MeshBasicMaterial({ color: 0x5ff2e6 }));
    light.position.y = 1.35;
    light.userData.noOutline = true;
    const glow = mesh(new THREE.CylinderGeometry(0.26, 0.26, 2.5, 10), new THREE.MeshBasicMaterial({
      color: 0x39c5bb, transparent: true, opacity: 0.28, depthWrite: false
    }));
    glow.position.y = 1.35;
    const grip = mesh(new THREE.CylinderGeometry(0.15, 0.15, 0.7, 10), toon(0x2b3237));
    grip.position.y = -0.1;
    root.add(light, glow, grip);
    return root;
  }

  // ---- Hats (children of the head bone; +Y up, +Z towards the camera) -----------
  function buildSanta() {
    const root = new THREE.Group();
    const cone = mesh(new THREE.ConeGeometry(1.95, 3.2, 20, 1, true), toon(0xd8283a, { side: THREE.DoubleSide }));
    cone.position.y = 1.6;
    const top = new THREE.Group();
    top.position.y = 3.1;
    const flop = mesh(new THREE.ConeGeometry(0.45, 1.4, 12), toon(0xd8283a));
    flop.rotation.z = -1.9;
    flop.position.set(0.6, -0.3, 0);
    const pompom = mesh(new THREE.SphereGeometry(0.42, 12, 8), toon(0xffffff));
    pompom.position.set(1.25, -0.55, 0);
    top.add(flop, pompom);
    const brim = mesh(new THREE.TorusGeometry(1.95, 0.42, 8, 24), toon(0xffffff));
    brim.rotation.x = Math.PI / 2;
    root.add(cone, top, brim);
    return root;
  }

  function buildWitch() {
    const root = new THREE.Group();
    const cloth = toon(0x2a1f3d);

    // A shallow, uneven curve keeps the brim soft without changing its familiar footprint.
    const brimGeometry = new THREE.CylinderGeometry(3.3, 3.3, 0.16, 48, 2);
    const brimPositions = brimGeometry.attributes.position;
    for (let i = 0; i < brimPositions.count; i += 1) {
      const x = brimPositions.getX(i);
      const y = brimPositions.getY(i);
      const z = brimPositions.getZ(i);
      const radius = Math.min(1, Math.hypot(x, z) / 3.3);
      const angle = Math.atan2(z, x);
      const lift = radius * radius * (
        0.045 + Math.sin(angle - 0.45) * 0.055 + Math.cos(angle * 2 + 0.35) * 0.022
      );
      brimPositions.setXYZ(i, x, y + lift, z * 0.9);
    }
    brimPositions.needsUpdate = true;
    brimGeometry.computeVertexNormals();
    const brim = mesh(brimGeometry, cloth);
    brim.name = 'witch-brim';

    const spine = new THREE.CatmullRomCurve3([
      new THREE.Vector3(0, 0.05, 0),
      new THREE.Vector3(0.02, 0.85, 0),
      new THREE.Vector3(-0.08, 1.75, 0.02),
      new THREE.Vector3(0.12, 2.55, 0.02),
      new THREE.Vector3(0.48, 3.18, 0.08),
      new THREE.Vector3(0.98, 3.55, 0.17),
      new THREE.Vector3(1.42, 3.42, 0.24),
      new THREE.Vector3(1.72, 2.95, 0.31)
    ], false, 'catmullrom', 0.5);
    const bodyRadius = (t, angle = 0) => {
      const tailTaper = 1 - THREE.MathUtils.smoothstep(t, 0.58, 0.94) * 0.42;
      return (
        1.7 * Math.pow(1 - t, 0.78) * tailTaper + 0.012
      ) * (1 + Math.sin(angle * 3 + 0.7) * 0.015 * (1 - t));
    };
    const sweptCloth = (start, end, segments, radiusAt) => {
      const geometry = new THREE.BufferGeometry();
      const radialSegments = 24;
      const positions = [];
      const indices = [];
      const forward = new THREE.Vector3(0, 0, 1);
      let previousNormal = null;

      for (let row = 0; row <= segments; row += 1) {
        const localT = row / segments;
        const t = start + (end - start) * localT;
        const centre = spine.getPointAt(t);
        const tangent = spine.getTangentAt(t).normalize();
        const normal = new THREE.Vector3().crossVectors(tangent, forward).normalize();
        if (previousNormal && normal.dot(previousNormal) < 0) normal.negate();
        const binormal = new THREE.Vector3().crossVectors(tangent, normal).normalize();
        previousNormal = normal;

        for (let column = 0; column < radialSegments; column += 1) {
          const angle = column / radialSegments * Math.PI * 2;
          const radius = radiusAt(t, angle);
          positions.push(
            centre.x + normal.x * Math.cos(angle) * radius + binormal.x * Math.sin(angle) * radius,
            centre.y + normal.y * Math.cos(angle) * radius + binormal.y * Math.sin(angle) * radius,
            centre.z + normal.z * Math.cos(angle) * radius + binormal.z * Math.sin(angle) * radius
          );
        }
      }
      for (let row = 0; row < segments; row += 1) {
        for (let column = 0; column < radialSegments; column += 1) {
          const next = (column + 1) % radialSegments;
          const a = row * radialSegments + column;
          const b = row * radialSegments + next;
          const c = (row + 1) * radialSegments + next;
          const d = (row + 1) * radialSegments + column;
          indices.push(a, b, d, b, c, d);
        }
      }
      const base = positions.length / 3;
      const basePoint = spine.getPointAt(start);
      positions.push(basePoint.x, basePoint.y, basePoint.z);
      const tip = positions.length / 3;
      const tipPoint = spine.getPointAt(end);
      positions.push(tipPoint.x, tipPoint.y, tipPoint.z);
      const lastRing = segments * radialSegments;
      for (let column = 0; column < radialSegments; column += 1) {
        const next = (column + 1) % radialSegments;
        indices.push(base, next, column);
        indices.push(tip, lastRing + column, lastRing + next);
      }
      geometry.setAttribute('position', new THREE.Float32BufferAttribute(positions, 3));
      geometry.setIndex(indices);
      geometry.computeVertexNormals();
      geometry.computeBoundingBox();
      geometry.computeBoundingSphere();
      return geometry;
    };

    const cone = mesh(sweptCloth(0, 1, 30, bodyRadius), cloth);
    cone.name = 'witch-crown';
    const band = mesh(sweptCloth(0.035, 0.18, 5, (t, angle) => bodyRadius(t, angle) + 0.045), toon(TEAL));
    band.name = 'witch-band';

    const roundedRectangle = (path, left, bottom, width, height, radius) => {
      const right = left + width;
      const top = bottom + height;
      path.moveTo(left + radius, bottom);
      path.lineTo(right - radius, bottom);
      path.quadraticCurveTo(right, bottom, right, bottom + radius);
      path.lineTo(right, top - radius);
      path.quadraticCurveTo(right, top, right - radius, top);
      path.lineTo(left + radius, top);
      path.quadraticCurveTo(left, top, left, top - radius);
      path.lineTo(left, bottom + radius);
      path.quadraticCurveTo(left, bottom, left + radius, bottom);
    };
    const buckleShape = new THREE.Shape();
    roundedRectangle(buckleShape, -0.38, -0.29, 0.76, 0.58, 0.1);
    const buckleHole = new THREE.Path();
    roundedRectangle(buckleHole, -0.24, -0.15, 0.48, 0.3, 0.045);
    buckleShape.holes.push(buckleHole);
    const buckleGeometry = new THREE.ExtrudeGeometry(buckleShape, {
      depth: 0.1,
      steps: 1,
      bevelEnabled: true,
      bevelSegments: 2,
      bevelSize: 0.025,
      bevelThickness: 0.025,
      curveSegments: 4
    });
    buckleGeometry.translate(0, 0, -0.05);
    const buckle = mesh(buckleGeometry, toon(0xf2c94c));
    buckle.name = 'witch-buckle';
    buckle.position.set(0, 0.45, 1.66);
    root.add(brim, cone, band, buckle);
    return root;
  }

  function buildParty() {
    const root = new THREE.Group();
    const geometry = new THREE.ConeGeometry(0.95, 2.3, 18, 6);
    const colors = [];
    const position = geometry.attributes.position;
    const pink = new THREE.Color(0xff7aa8);
    const teal = new THREE.Color(TEAL);
    for (let i = 0; i < position.count; i += 1) {
      const stripe = Math.floor((position.getY(i) + 1.15) / 2.3 * 6 + 0.5) % 2;
      const c = stripe ? pink : teal;
      colors.push(c.r, c.g, c.b);
    }
    geometry.setAttribute('color', new THREE.Float32BufferAttribute(colors, 3));
    const cone = mesh(geometry, toon(0xffffff, { vertexColors: true }));
    cone.position.y = 1.15;
    const pompom = mesh(new THREE.SphereGeometry(0.32, 10, 8), toon(0xfff2a8));
    pompom.position.y = 2.35;
    root.add(cone, pompom);
    return root;
  }

  function buildBeanie() {
    const root = new THREE.Group();
    const cap = mesh(new THREE.SphereGeometry(2.05, 20, 10, 0, Math.PI * 2, 0, Math.PI * 0.5), toon(0xf4fbff));
    cap.scale.set(1, 0.85, 1);
    const cuff = mesh(new THREE.CylinderGeometry(2.12, 2.12, 0.6, 24, 1, true), toon(0x8fd3f0, { side: THREE.DoubleSide }));
    cuff.position.y = 0.15;
    const pompom = mesh(new THREE.SphereGeometry(0.55, 12, 8), toon(0x8fd3f0));
    pompom.position.y = 1.9;
    root.add(cap, cuff, pompom);
    return root;
  }

  const hand = {
    umbrella: noRaycast(buildUmbrella()),
    closedUmbrella: noRaycast(buildClosedUmbrella()),
    drink: noRaycast(buildDrink()),
    leek: noRaycast(buildLeek()),
    fan: noRaycast(buildFan()),
    glowLeft: noRaycast(buildGlowstick()),
    glowRight: noRaycast(buildGlowstick())
  };
  const hats = {
    santa: noRaycast(buildSanta()),
    witch: noRaycast(buildWitch()),
    party: noRaycast(buildParty()),
    beanie: noRaycast(buildBeanie())
  };
  const group = new THREE.Group();
  group.name = 'miku-props';
  for (const object of Object.values(hand)) {
    object.visible = false;
    group.add(object);
  }
  for (const object of Object.values(hats)) object.visible = false;

  let hatParent = null;
  let wornHat = null;

  /** Puts a hat on (or takes it off with null). `head` is the head bone. */
  function wearHat(name, head, placement) {
    const next = name ? hats[name] : null;
    if (head && hatParent !== head) {
      for (const hat of Object.values(hats)) head.add(hat);
      hatParent = head;
    }
    for (const [key, hat] of Object.entries(hats)) {
      hat.visible = key === name;
      if (key === name && placement) {
        hat.position.set(...placement.position);
        hat.rotation.set(...placement.rotation);
        hat.scale.setScalar(placement.scale ?? 1);
      }
    }
    wornHat = next ? name : null;
  }

  function hideHandProps() {
    for (const object of Object.values(hand)) object.visible = false;
  }

  return { group, hand, hats, wearHat, hideHandProps, get wornHat() { return wornHat; } };
}

/**
 * Which hat she wears for the special days the app tells her about (most specific first).
 * Returns null on ordinary days.
 */
export function hatFor(keys = []) {
  const today = new Set(keys);
  if (today.has('birthday') || today.has('anniversary')) return 'party';
  if (today.has('christmas') || today.has('christmasSeason')) return 'santa';
  if (today.has('halloween') || today.has('halloweenSeason')) return 'witch';
  if (today.has('snowMiku')) return 'beanie';
  return null;
}

const OUTDOOR_SCENES = new Set(['ikebukuro', 'akihabara', 'shinjuku', 'shibuya']);
// Indoors but just in from the rain: the Shibuya scene is inside the station's ticket gates,
// where nobody opens an umbrella; she carries hers closed.
const JUST_IN_FROM_THE_RAIN = new Set(['shibuya-station']);

/**
 * What she should be holding right now, if anything. Pure, so it can be tested.
 * `idle` is false while she's being touched, carried, dragged or reacting to something.
 */
export function chooseHandProp({
  weather = 'clear', scene = '', hour = 12, idle = true, awake = true,
  drinkUntil = 0, leekUntil = 0, fanUntil = 0, cheerUntil = 0, now = 0
} = {}) {
  if (!awake || !idle) return null;
  const wet = ['rain', 'storm', 'snow'].includes(weather);
  if (wet && OUTDOOR_SCENES.has(scene)) return 'umbrella';
  if (wet && JUST_IN_FROM_THE_RAIN.has(scene)) return 'closedUmbrella';
  if (now < cheerUntil) return 'glowsticks';
  if (now < leekUntil) return 'leek';
  if (now < fanUntil) return 'fan';
  if (now < drinkUntil) return 'drink';
  return null;
}

/** Afternoon tea time: 14:30–16:30. */
export function isTeaTime(hour) {
  return Number.isFinite(hour) && hour >= 14.5 && hour < 16.5;
}
