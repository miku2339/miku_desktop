// Extra idle actions, reactions and micro-expressions.
//
// Everything here is layered on top of the base pose through a small API that the
// character page passes in (bone rotations, morphs, speech, little floating symbols),
// so these stay independent of how the page is wired up.
//
// Bone axes (three.js MMD, model facing the camera): for the left arm +z raises it,
// -y swings it forwards; an elbow bends the forearm forwards with -y (left) / +y (right).
// Fingers curl towards the palm with -z (left) / +z (right). Right-side values mirror.

const FINGERS = ['人指', '中指', '薬指', '小指'];

export function createGestures(api) {
  const {
    rotateBone, twistBone, offsetBone, setMorph, setSmile, scaleMorph,
    blinkAmount, easeBetween, envelope, symbol, say, setTurnOffset, lift
  } = api;

  const mirror = side => (side === '右' ? -1 : 1);
  const span = (progress, start, end, fade = 0.08) => (
    easeBetween(progress, start, start + fade) * (1 - easeBetween(progress, end - fade, end))
  );

  function curl(side, amount, fingers = FINGERS, thumb = amount) {
    const s = -mirror(side);
    for (const finger of fingers) {
      rotateBone(`${side}${finger}１`, 0, 0, s * amount * 0.8);
      rotateBone(`${side}${finger}２`, 0, 0, s * amount * 1.1);
      rotateBone(`${side}${finger}３`, 0, 0, s * amount * 0.9);
    }
    rotateBone(`${side}親指１`, 0, s * thumb * 0.4, s * thumb * 0.3);
    rotateBone(`${side}親指２`, 0, 0, s * thumb * 0.6);
  }

  const fist = (side, amount) => curl(side, 1.35 * amount);
  // Index and middle up, the rest folded: a "V".
  const peace = (side, amount) => {
    curl(side, 1.4 * amount, ['薬指', '小指'], 1.1 * amount);
    rotateBone(`${side}人指１`, 0, mirror(side) * 0.12 * amount, 0);
    rotateBone(`${side}中指１`, 0, -mirror(side) * 0.1 * amount, 0);
  };
  const point = (side, amount) => curl(side, 1.35 * amount, ['中指', '薬指', '小指'], 1.1 * amount);

  // Hand up by the face, fitted against the model so the palm (not the back of the hand
  // or the sleeve cuff) faces the right way: shoulder lift, upper arm forward / raise, elbow,
  // forearm twist, wrist. Left-side values; the right side mirrors.
  const FACE_SPOTS = {
    // Covering her mouth: palm on the mouth, fingers up (yawn, giggle, sneeze).
    mouth: { shoulder: 0.169, armY: 1.235, armZ: 0.04, elbowY: -1.175, elbowZ: 2.899, twist: 0.973, wristX: -0.49, wristZ: 0.36 },
    // Thinking: a loosely curled hand under the chin, palm towards it.
    chin: { shoulder: -0.169, armY: 0.942, armZ: -0.012, elbowY: -0.751, elbowZ: 3.106, twist: 1.145, wristX: -0.265, wristZ: 0.586 },
    // One of both hands up by her mouth, elbows out so the forearms don't cross (a gasp).
    gasp: { shoulder: 0.546, armY: 1.567, armZ: -0.407, elbowY: 2.119, elbowZ: 2.026, twist: -0.468, wristX: 0.395, wristZ: -0.063 },
    // Beside the eye, palm to the front (the idol "V").
    temple: { shoulder: 0.209, armY: 0.953, armZ: 1.065, elbowY: 0.658, elbowZ: 1.694, twist: -0.352, wristX: -0.196, wristZ: -0.55 }
  };
  function handToFace(side, weight, spot = 'chin') {
    if (weight <= 0.001) return;
    const s = mirror(side);
    const p = FACE_SPOTS[spot] ?? FACE_SPOTS.chin;
    rotateBone(`${side}肩`, 0, 0, s * p.shoulder * weight);
    rotateBone(`${side}腕`, 0, -s * p.armY * weight, s * p.armZ * weight);
    rotateBone(`${side}ひじ`, 0, -s * p.elbowY * weight, s * p.elbowZ * weight);
    twistBone(`${side}ひじ`, `${side}手首`, s * p.twist * weight);
    rotateBone(`${side}手首`, s * p.wristX * weight, 0, s * p.wristZ * weight);
  }

  function armUp(side, weight, { height = 1, bend = 0.35 } = {}) {
    const s = mirror(side);
    rotateBone(`${side}肩`, 0, 0, s * 0.14 * weight);
    rotateBone(`${side}腕`, 0, -s * 0.25 * weight, s * (1.1 + height * 1.0) * weight);
    rotateBone(`${side}ひじ`, 0, 0, s * bend * weight);
  }

  function ahoge(bounce) {
    rotateBone('アホ毛１', bounce * 0.5, 0, 0);
    rotateBone('アホ毛２', bounce * 0.7, 0, 0);
  }

  function hop(progress, elapsed, start, length, height = 0.35) {
    const local = (progress - start) / length;
    if (local <= 0 || local >= 1) return 0;
    const lift = Math.sin(local * Math.PI);
    // Feet are pinned to the floor every frame, so a hop has to lift the whole body.
    api.lift(height * lift * 4);
    for (const side of ['左', '右']) {
      rotateBone(`${side}足`, -0.2 * lift, 0, 0);
      rotateBone(`${side}ひざ`, 0.45 * lift, 0, 0);
      rotateBone(`${side}足首`, -0.2 * lift, 0, 0);
    }
    ahoge(-lift * 0.4 + Math.sin(local * Math.PI * 3) * 0.15);
    return lift;
  }

  // ---- idle actions ----------------------------------------------------------

  function dance(progress, elapsed, variant = {}) {
    const style = variant.style ?? 'sway';
    const weight = envelope(progress);
    const flip = variant.flip ?? 1;
    const beat = elapsed * Math.PI * 2 * 1.05 * (variant.speed ?? 1);
    const step = Math.sin(beat);
    const bounce = Math.abs(Math.sin(beat));
    offsetBone('センター', 0.12 * step * weight, 0, 0);
    rotateBone('下半身', 0, 0.08 * step * weight, -0.07 * step * weight);
    rotateBone('上半身', 0, -0.06 * step * weight, 0.05 * step * weight);
    rotateBone('頭', 0.03 * bounce * weight, 0, 0.08 * Math.sin(beat + 0.6) * weight);
    for (const [index, side] of ['左', '右'].entries()) {
      const s = mirror(side);
      const swing = Math.sin(beat + index * Math.PI);
      rotateBone(`${side}腕`, 0, -s * 0.25 * swing * weight, s * 0.2 * weight);
      rotateBone(`${side}ひじ`, 0, -s * (0.9 + 0.3 * swing) * weight, 0);
      rotateBone(`${side}ひざ`, 0.18 * Math.max(0, index ? -step : step) * weight, 0, 0);
    }
    ahoge(0.15 * Math.sin(beat * 2) * weight);
    setMorph('まばたき', Math.max(blinkAmount(elapsed), 0.55 * weight));
    setMorph('笑い', 0.35 * weight);
    setSmile(Math.max(0.12, 0.8 * weight));
    setMorph('あ', 0.12 * weight * (0.5 + 0.5 * Math.sin(beat * 2)));
    if (weight > 0.5 && Math.floor(elapsed * 1.6) !== Math.floor((elapsed - 0.05) * 1.6)) symbol('♪', 'hum', flip * 0.04);
    if (style === 'twirl') {
      // A full pirouette in the middle; the turn spring adds the follow-through.
      const spin = easeBetween(progress, 0.4, 0.62);
      setTurnOffset(flip * Math.PI * 2 * spin * (progress < 0.9 ? 1 : 0));
      if (progress > 0.4) say(variant, 1, 'dance');
    } else if (style === 'idol') {
      const pose = span(progress, 0.68, 0.96);
      if (pose > 0.001) idolPoseAt(pose, elapsed, variant.side ?? '右', flip);
      if (progress > 0.7) say(variant, 1, 'idol');
    } else if (progress > 0.3) say(variant, 1, 'dance');
  }

  function idolPoseAt(weight, elapsed, side, flip) {
    // Peace sign beside the eye, a wink, head tilted.
    const s = mirror(side);
    handToFace(side, weight, 'temple');
    peace(side, weight);
    rotateBone('頭', 0, 0, s * 0.12 * weight);
    rotateBone('上半身', 0, 0, s * 0.05 * weight);
    offsetBone('センター', -s * 0.08 * weight, 0, 0);
    setMorph('まばたき', 0);
    setMorph(side === '右' ? 'ウィンク右' : 'ウィンク', 0.9 * weight);
    setMorph('照れ', 0.4 * weight);
    setSmile(Math.max(0.12, weight));
    setMorph('ワ', 0.25 * weight);
  }

  function idolPose(progress, elapsed, variant = {}) {
    const weight = span(progress, 0.02, 0.95, 0.12);
    idolPoseAt(weight, elapsed, variant.side ?? '右', variant.flip ?? 1);
    hop(progress, elapsed, 0.02, 0.2, 0.25);
    if (progress > 0.12) say(variant, 1, 'idol');
  }

  function think(progress, elapsed, variant = {}) {
    const side = variant.side ?? '右';
    const s = mirror(side);
    const idea = variant.style === 'idea';
    const pondering = span(progress, 0.02, idea ? 0.66 : 0.95, 0.12);
    handToFace(side, pondering, 'chin');
    curl(side, 0.7 * pondering);
    rotateBone('頭', -0.05 * pondering, -s * 0.08 * pondering, s * 0.1 * pondering);
    rotateBone('両目', -0.06 * pondering, -s * 0.12 * pondering, 0);
    setMorph('困る', 0.45 * pondering);
    setMorph('∧', 0.25 * pondering);
    setMorph('まばたき', blinkAmount(elapsed) * (1 - pondering * 0.5));
    if (pondering > 0.6 && Math.floor(elapsed / 1.4) !== Math.floor((elapsed - 0.05) / 1.4)) symbol('?', 'think', -s * 0.05);
    if (progress > 0.15) say(variant, 1, 'think');
    if (!idea) return;
    // "I've got it!": finger up, eyes sparkle, a little hop.
    const eureka = span(progress, 0.62, 0.98, 0.06);
    if (eureka > 0.001) {
      armUp(side, eureka, { height: 0.15, bend: 1.2 });
      point(side, eureka);
      setMorph('星目', 0.8 * eureka);
      setSmile(Math.max(0.12, 0.85 * eureka));
      setMorph('あ', 0.3 * eureka);
      hop(progress, elapsed, 0.63, 0.12, 0.18);
      if (progress > 0.64) {
        if ((variant.symbols ?? 0) < 1) {
          variant.symbols = 1;
          symbol('!', 'idea', 0);
        }
        say(variant, 2, 'idea');
      }
    }
  }

  function tidyHair(progress, elapsed, variant = {}) {
    // Both hands up to the twintail ties, a little adjust, then a satisfied nod.
    const weight = span(progress, 0.03, 0.85, 0.15);
    const fiddle = Math.sin(elapsed * 7) * 0.06 * weight;
    for (const side of ['左', '右']) {
      const s = mirror(side);
      rotateBone(`${side}肩`, 0, 0, s * 0.12 * weight);
      rotateBone(`${side}腕`, 0, s * 0.1 * weight, s * (1.55 + fiddle) * weight);
      rotateBone(`${side}ひじ`, 0, 0, s * 2.0 * weight);
      curl(side, 0.6 * weight);
    }
    rotateBone('頭', 0.06 * weight, 0, 0.04 * Math.sin(elapsed * 2.2) * weight);
    ['左髪１', '右髪１'].forEach((name, index) => rotateBone(name, 0, 0, (index ? -1 : 1) * fiddle * 0.6));
    setMorph('まばたき', Math.max(blinkAmount(elapsed), 0.35 * weight));
    setSmile(Math.max(0.12, 0.35 * weight));
    const done = span(progress, 0.84, 1, 0.06);
    if (done > 0.001) {
      rotateBone('頭', 0.08 * Math.sin((progress - 0.84) / 0.16 * Math.PI) * done, 0, 0);
      setSmile(0.75 * done);
      setMorph('ω', 0.3 * done);
      say(variant, 1, 'tidy');
    }
  }

  function yawn(progress, elapsed, variant = {}) {
    const side = variant.side ?? '右';
    const big = span(progress, 0.08, 0.6, 0.14);
    const hand = span(progress, 0.14, 0.62, 0.1);
    rotateBone('上半身', -0.08 * big, 0, 0);
    rotateBone('頭', -0.12 * big, 0, 0);
    offsetBone('センター', 0, 0.06 * big, 0);
    handToFace(side, hand, 'mouth');
    curl(side, 0.25 * hand);
    setMorph('まばたき', Math.max(blinkAmount(elapsed), 0.9 * big));
    setMorph('あ', 0.85 * big);
    setMorph('お', 0.3 * big);
    setMorph('困る', 0.3 * big);
    const after = span(progress, 0.6, 1, 0.1);
    setMorph('涙', 0.5 * after);
    setMorph('なごみ', 0.3 * after);
    if (progress > 0.62) say(variant, 1, 'yawn');
  }

  function doze(progress, elapsed, variant = {}) {
    // Nods off standing up, then jolts awake and pretends nothing happened.
    const sleepy = span(progress, 0.02, 0.7, 0.18);
    const nod = Math.sin(elapsed * 0.9) * 0.5 + 0.5;
    rotateBone('首', 0.2 * sleepy * (0.6 + 0.4 * nod), 0, 0.05 * sleepy);
    rotateBone('頭', 0.18 * sleepy * (0.6 + 0.4 * nod), 0, 0.08 * sleepy);
    rotateBone('上半身', 0.04 * sleepy, 0, 0.02 * sleepy);
    setMorph('まばたき', Math.max(blinkAmount(elapsed), sleepy));
    setMorph('なごみ', 0.4 * sleepy);
    setMorph('う', 0.2 * sleepy);
    if (sleepy > 0.7 && Math.floor(elapsed / 1.1) !== Math.floor((elapsed - 0.05) / 1.1)) symbol('z', 'sleep', 0.04);
    if (progress > 0.2) say(variant, 1, 'doze');
    const awake = span(progress, 0.7, 1, 0.03);
    if (awake > 0.001) {
      const jolt = span(progress, 0.7, 0.82, 0.03);
      lift(0.55 * jolt);
      rotateBone('頭', -0.1 * jolt, 0, 0);
      for (const side of ['左', '右']) rotateBone(`${side}腕`, 0, 0, mirror(side) * 0.35 * jolt);
      ahoge(-0.5 * jolt);
      setMorph('びっくり', 0.9 * jolt);
      setMorph('照れ', 0.8 * awake);
      setMorph('困る', 0.4 * awake * (1 - jolt));
      setSmile(Math.max(0.12, 0.4 * awake * (1 - jolt)));
      if (progress > 0.74) say(variant, 2, 'wake');
    }
  }

  function sneeze(progress, elapsed, variant = {}) {
    // "Ha… ha… ha-CHOO!" then a sheepish tongue-out.
    const windUp = easeBetween(progress, 0.05, 0.45) * (1 - easeBetween(progress, 0.47, 0.5));
    const burst = span(progress, 0.47, 0.62, 0.03);
    const after = span(progress, 0.6, 1, 0.08);
    rotateBone('上半身', -0.12 * windUp + 0.25 * burst, 0, 0);
    rotateBone('頭', -0.18 * windUp + 0.3 * burst, 0, 0);
    offsetBone('センター', 0, 0.05 * windUp - 0.08 * burst, 0);
    // The hand comes up to cover the sneeze just in time, then drops away.
    handToFace(variant.side ?? '右', easeBetween(progress, 0.3, 0.44) * (1 - easeBetween(progress, 0.6, 0.72)), 'mouth');
    setMorph('まばたき', Math.max(0.6 * windUp, burst));
    setMorph('あ', 0.55 * windUp);
    setMorph('困る', 0.6 * windUp);
    setMorph('はぅ', 0.9 * burst);
    setMorph('い', 0.5 * burst);
    ahoge(0.6 * burst);
    if (progress > 0.1) say(variant, 1, 'sneezeWindUp');
    if (progress > 0.47) say(variant, 2, 'sneeze');
    if (after > 0.001) {
      setMorph('てへぺろ', 0.85 * after);
      setMorph('照れ', 0.6 * after);
      rotateBone('頭', 0, 0, 0.1 * after * (variant.flip ?? 1));
    }
  }

  function cheer(progress, elapsed, variant = {}) {
    // Fist pump and a hop: "Let's do our best!"
    const side = variant.side ?? '右';
    const ready = span(progress, 0.05, 0.92, 0.12);
    const pump = Math.max(0, Math.sin((progress - 0.3) * Math.PI * 4)) * span(progress, 0.3, 0.8, 0.05);
    armUp(side, ready * (0.3 + 0.7 * pump), { height: 0.7, bend: 0.4 + 0.5 * (1 - pump) });
    fist(side, ready);
    handToFace(side === '右' ? '左' : '右', 0.55 * ready, 'chin');
    fist(side === '右' ? '左' : '右', ready);
    hop(progress, elapsed, 0.3, 0.18, 0.3);
    hop(progress, elapsed, 0.55, 0.18, 0.3);
    setMorph('ｷﾘｯ', 0.5 * ready);
    setSmile(Math.max(0.12, 0.9 * ready));
    setMorph('あ', 0.35 * ready * (0.4 + 0.6 * pump));
    if (progress > 0.28) say(variant, 1, 'cheer');
  }

  function bored(progress, elapsed, variant = {}) {
    // Rocks on her heels, arms swinging, glancing at you: "play with me~".
    const weight = envelope(progress);
    const rock = Math.sin(elapsed * Math.PI * 2 * 0.7);
    offsetBone('センター', 0, 0.05 * Math.max(0, rock) * weight, 0);
    rotateBone('上半身', -0.05 * rock * weight, 0, 0);
    for (const side of ['左', '右']) {
      rotateBone(`${side}足首`, 0.18 * Math.max(0, rock) * weight, 0, 0);
      rotateBone(`${side}腕`, 0, mirror(side) * (0.25 + 0.2 * rock) * weight, 0);
    }
    const glance = span(progress, 0.45, 0.85, 0.12);
    rotateBone('頭', 0.04 * weight, 0.12 * (variant.flip ?? 1) * (1 - glance) * weight, 0.05 * rock * weight);
    setMorph('じと目', 0.25 * weight * (1 - glance));
    setMorph('ω', 0.4 * weight);
    setMorph('照れ', 0.3 * glance);
    setSmile(Math.max(0.12, 0.4 * glance));
    if (progress > 0.5) say(variant, 1, 'bored');
  }

  function shiver(progress, elapsed, variant = {}) {
    // Hugs herself and shivers in the snow.
    const weight = envelope(progress);
    const shake = Math.sin(elapsed * 38) * 0.012 * weight;
    for (const side of ['左', '右']) {
      const s = mirror(side);
      // Arms crossed over the chest, hugging herself.
      rotateBone(`${side}腕`, 0, -s * 1.2 * weight, s * 0.35 * weight);
      rotateBone(`${side}ひじ`, 0, -s * 2.1 * weight, 0);
      curl(side, 0.5 * weight);
    }
    rotateBone('上半身', 0.08 * weight, 0, shake);
    rotateBone('頭', 0.06 * weight, 0, shake * 1.5);
    offsetBone('センター', shake * 3, -0.04 * weight, 0);
    setMorph('はぅ', 0.6 * weight);
    setMorph('困る', 0.7 * weight);
    setMorph('い', 0.35 * weight);
    if (progress > 0.2) say(variant, 1, 'shiver');
  }

  function skyLook(progress, elapsed, variant = {}) {
    // Looks up and holds out a palm to feel the rain / catch a snowflake.
    const side = variant.side ?? '右';
    const s = mirror(side);
    const look = span(progress, 0.03, 0.95, 0.14);
    const palm = span(progress, 0.2, 0.9, 0.12);
    rotateBone('首', -0.12 * look, 0, 0);
    rotateBone('頭', -0.2 * look, -s * 0.05 * look, 0);
    rotateBone('両目', -0.1 * look, 0, 0);
    // Hand out in front, palm up (fitted against the model).
    rotateBone(`${side}肩`, 0, 0, -s * 0.158 * palm);
    rotateBone(`${side}腕`, 0, -s * 0.198 * palm, -s * 0.38 * palm);
    rotateBone(`${side}ひじ`, 0, -s * 1.213 * palm, s * 0.942 * palm);
    twistBone(`${side}ひじ`, `${side}手首`, -s * 1.303 * palm);
    rotateBone(`${side}手首`, s * 0.596 * palm, 0, s * 0.292 * palm);
    curl(side, 0.25 * palm);
    setSmile(Math.max(0.12, 0.5 * look));
    setMorph('あ', 0.15 * look);
    if (progress > 0.3) say(variant, 1, variant.style === 'snow' ? 'snowCatch' : 'rainFeel');
  }

  // ---- reactions -------------------------------------------------------------

  function startle(progress, elapsed, variant = {}) {
    // Thunder! Jumps, covers her ears, then laughs it off nervously.
    const jump = span(progress, 0, 0.22, 0.04);
    const ears = span(progress, 0.06, 0.78, 0.08);
    lift(0.9 * jump);
    ahoge(-0.6 * jump);
    for (const side of ['左', '右']) {
      const s = mirror(side);
      rotateBone(`${side}肩`, 0, 0, s * 0.15 * ears);
      rotateBone(`${side}腕`, 0, -s * 0.35 * ears, s * 1.25 * ears);
      rotateBone(`${side}ひじ`, 0, 0, s * 2.35 * ears);
      curl(side, 0.3 * ears);
    }
    rotateBone('頭', 0.1 * ears, 0, 0);
    rotateBone('上半身', 0.06 * ears, 0, Math.sin(elapsed * 30) * 0.01 * ears);
    setMorph('びっくり', 0.9 * jump);
    setMorph('はぅ', 0.85 * ears * (1 - jump));
    setMorph('涙', 0.5 * ears);
    setMorph('困る', 0.8 * ears);
    setMorph('い', 0.4 * ears);
    const relief = span(progress, 0.75, 1, 0.08);
    setMorph('困る', 0.5 * relief);
    setSmile(Math.max(0.12, 0.5 * relief));
    if (progress > 0.04) say(variant, 1, 'thunder', true);
  }

  // ---- body language for chat replies ---------------------------------------------
  //
  // Short, readable gestures that go with what she's saying. They never speak themselves:
  // the reply is already in the speech bubble.

  /** Hands clasped in front of her skirt. */
  function handsTogether(weight) {
    for (const side of ['左', '右']) {
      const s = mirror(side);
      rotateBone(`${side}腕`, 0, -s * 0.62 * weight, -s * 0.12 * weight);
      rotateBone(`${side}ひじ`, 0, -s * 0.75 * weight, 0);
      rotateBone(`${side}手首`, 0, 0, -s * 0.25 * weight);
      curl(side, 0.35 * weight);
    }
  }

  function bow(progress, elapsed, variant = {}) {
    // A polite little bow (thanks, sorry, good night).
    const weight = envelope(progress);
    const dip = span(progress, 0.15, 0.78, 0.2);
    handsTogether(weight);
    rotateBone('上半身', 0.42 * dip, 0, 0);
    rotateBone('下半身', -0.05 * dip, 0, 0);
    rotateBone('首', 0.12 * dip, 0, 0);
    rotateBone('頭', 0.12 * dip, 0, 0);
    setMorph('まばたき', Math.max(blinkAmount(elapsed), 0.65 * dip));
    setSmile(Math.max(0.12, 0.4 * weight));
  }

  function shakeHead(progress, elapsed, variant = {}) {
    // "No, no": a few quick shakes of the head, a little frown.
    const weight = envelope(progress);
    const shake = Math.sin(progress * Math.PI * 7) * span(progress, 0.08, 0.8, 0.1);
    rotateBone('首', 0, 0.18 * shake, 0);
    rotateBone('頭', 0.03 * weight, 0.24 * shake, 0);
    setMorph('困る', 0.45 * weight);
    setMorph('∧', 0.3 * weight);
    setMorph('まばたき', Math.max(blinkAmount(elapsed), 0.3 * weight));
  }

  function laugh(progress, elapsed, variant = {}) {
    // Giggles behind her hand, shoulders bouncing.
    const side = variant.side ?? '右';
    const weight = envelope(progress);
    const giggle = Math.abs(Math.sin(elapsed * 11)) * span(progress, 0.1, 0.85, 0.1);
    handToFace(side, weight, 'mouth');
    curl(side, 0.45 * weight);
    rotateBone('上半身', 0.05 * weight + 0.03 * giggle, 0, 0.03 * mirror(side) * weight);
    rotateBone('頭', 0.04 * weight, 0, -0.08 * mirror(side) * weight);
    offsetBone('センター', 0, 0.06 * giggle, 0);
    for (const s of ['左肩', '右肩']) rotateBone(s, 0, 0, (s === '左肩' ? 1 : -1) * 0.06 * giggle);
    setMorph('笑い', 0.9 * weight);
    setSmile(Math.max(0.12, weight));
    setMorph('あ', 0.25 * giggle);
  }

  function clap(progress, elapsed, variant = {}) {
    // Claps her hands in front of her chest: "yay!"
    const weight = envelope(progress);
    const beat = span(progress, 0.15, 0.85, 0.08);
    const open = 0.5 + 0.5 * Math.cos(elapsed * Math.PI * 2 * 2.6);
    // Palms facing each other (fingers curl towards the other hand), elbows down, forearms
    // up, wrists apart so the hands meet in a V and the wide cuffs don't run into each
    // other; fitted against the model so the forearm twist stays small.
    for (const side of ['左', '右']) {
      const s = mirror(side);
      rotateBone(`${side}肩`, 0, 0, s * 0.05 * weight);
      rotateBone(`${side}腕`, 0, -s * (1.05 - 0.12 * open * beat) * weight, (-s * 0.43 + 0.08) * weight);
      rotateBone(`${side}ひじ`, 0, -s * (1.1 - 0.28 * open * beat) * weight, s * 1.32 * weight);
      twistBone(`${side}ひじ`, `${side}手首`, -s * 0.66 * weight);
      rotateBone(`${side}手首`, 0, 0, -s * 0.02 * weight);
    }
    setSmile(Math.max(0.12, 0.85 * weight));
    setMorph('笑い', 0.4 * weight);
    setMorph('ワ', 0.25 * weight);
    if (beat > 0.5 && open < 0.08 && Math.floor(elapsed * 2.6) !== Math.floor((elapsed - 0.05) * 2.6)) symbol('♪', 'hum', 0);
  }

  function shy(progress, elapsed, variant = {}) {
    // Praised: hands clasped, swaying, looking down and away with a smile.
    const weight = envelope(progress);
    const sway = Math.sin(elapsed * 2.4) * weight;
    const flip = variant.flip ?? 1;
    handsTogether(weight);
    rotateBone('上半身', 0.04 * weight, 0.05 * sway, 0.03 * sway);
    rotateBone('下半身', 0, -0.04 * sway, 0);
    rotateBone('頭', 0.12 * weight, -flip * 0.12 * weight, flip * 0.08 * weight);
    rotateBone('両目', 0.08 * weight, flip * 0.1 * weight, 0);
    setMorph('照れ', 0.55 * weight);
    setMorph('なごみ', 0.3 * weight);
    setSmile(Math.max(0.12, 0.6 * weight));
  }

  function sad(progress, elapsed, variant = {}) {
    // Shoulders drop, head down, a small frown.
    const weight = envelope(progress);
    rotateBone('上半身', 0.08 * weight, 0, 0);
    rotateBone('首', 0.12 * weight, 0, 0);
    rotateBone('頭', 0.14 * weight, 0, 0.04 * (variant.flip ?? 1) * weight);
    for (const side of ['左', '右']) {
      const s = mirror(side);
      rotateBone(`${side}肩`, 0, 0, -s * 0.08 * weight);
      rotateBone(`${side}腕`, 0, -s * 0.1 * weight, -s * 0.06 * weight);
    }
    setMorph('困る', 0.8 * weight);
    setMorph('口角下げ', 0.45 * weight);
    setMorph('まばたき', Math.max(blinkAmount(elapsed), 0.35 * weight));
    setMorph('涙', 0.35 * span(progress, 0.3, 0.85, 0.15) * (variant.tears ? 1 : 0));
  }

  function pout(progress, elapsed, variant = {}) {
    // Hands on hips, cheeks puffed, looking away: "hmph!"
    const weight = envelope(progress);
    const flip = variant.flip ?? 1;
    for (const side of ['左', '右']) {
      const s = mirror(side);
      rotateBone(`${side}腕`, 0, s * 0.35 * weight, s * 0.1 * weight);
      rotateBone(`${side}ひじ`, 0, s * 0.9 * weight, s * 0.5 * weight);
    }
    rotateBone('頭', -0.08 * weight, -0.28 * flip * weight, 0.06 * flip * weight);
    rotateBone('上半身', -0.03 * weight, -0.1 * flip * weight, 0);
    setMorph('怒り', 0.55 * weight);
    setMorph('ω', 0.6 * weight);
    setMorph('照れ', 0.2 * weight);
  }

  function surprised(progress, elapsed, variant = {}) {
    // A little jump back, both hands up near her mouth.
    const jump = span(progress, 0, 0.18, 0.04);
    const hands = span(progress, 0.04, 0.85, 0.1);
    lift(0.6 * jump);
    offsetBone('センター', 0, 0, -0.3 * hands);
    for (const side of ['左', '右']) handToFace(side, hands, 'gasp');
    rotateBone('上半身', -0.06 * hands, 0, 0);
    ahoge(-0.5 * jump);
    setMorph('びっくり', 0.9 * span(progress, 0, 0.5, 0.06));
    setMorph('上', 0.6 * hands);
    setMorph('お', 0.4 * hands);
  }

  // ---- micro-expressions --------------------------------------------------------

  const MICRO = ['smile', 'brows', 'smug', 'pout', 'doubleBlink', 'lookAway', 'hum'];

  /** A brief flicker of feeling over the idle face. `progress` 0..1 over ~1.5 s. */
  function micro(type, progress, elapsed) {
    const weight = Math.sin(Math.min(1, Math.max(0, progress)) * Math.PI);
    switch (type) {
      case 'smile':
        setSmile(Math.max(0.12, 0.6 * weight));
        setMorph('照れ', 0.25 * weight);
        setMorph('なごみ', 0.2 * weight);
        break;
      case 'brows':
        setMorph('上', 0.7 * weight);
        rotateBone('頭', -0.03 * weight, 0, 0.04 * weight);
        break;
      case 'smug':
        setMorph('にやり', 0.55 * weight);
        setMorph('じと目', 0.2 * weight);
        break;
      case 'pout':
        setMorph('ω', 0.5 * weight);
        setMorph('照れ', 0.2 * weight);
        break;
      case 'doubleBlink': {
        const blink = Math.max(0, Math.sin(progress * Math.PI * 4));
        setMorph('まばたき', blink * 0.95);
        break;
      }
      case 'lookAway':
        rotateBone('両目', 0.04 * weight, 0.12 * weight, 0);
        rotateBone('頭', 0, 0.05 * weight, 0);
        break;
      default:
        setMorph('う', 0.25 * weight * (0.5 + 0.5 * Math.sin(elapsed * 9)));
        setMorph('まばたき', Math.max(blinkAmount(elapsed), 0.5 * weight));
    }
  }

  return {
    dance, idolPose, think, tidyHair, yawn, doze, sneeze, cheer, bored, shiver, skyLook,
    startle, bow, shakeHead, laugh, clap, shy, sad, pout, surprised, micro, MICRO, scaleMorph
  };
}

/** Phrases for the new actions, per language. */
export const GESTURE_PHRASES = {
  'zh-Hant': {
    dance: ['♪ 啦啦啦～', '一起跳吧！♪', '節奏來了～♪'],
    idol: ['Miku Miku～♪', '今天也是可愛的 Miku！', '耶～☆'],
    think: ['嗯……', '讓我想想…', '是什麼來著…'],
    idea: ['我知道了！', '想到了！☆', '原來如此！'],
    tidy: ['雙馬尾 OK！', '好，整齊了♪', '頭髮是偶像的生命！'],
    yawn: ['呼啊～…', '有點睏了…', '嗯…要休息一下嗎？'],
    doze: ['Zzz…', '嗯…蔥…', '呼…'],
    wake: ['我、我沒有睡著喔！', '咦？我剛剛睡著了？', '才、才沒有打瞌睡！'],
    sneezeWindUp: ['哈…哈……', '鼻子好癢…'],
    sneeze: ['哈啾！', '哈—啾！'],
    cheer: ['加油！', '今天也要努力喔！', '衝呀！'],
    bored: ['陪我玩嘛～', '好無聊喔…', '在忙嗎？'],
    shiver: ['好、好冷…', '要穿暖一點才行…', '嗚…手好冰。'],
    rainFeel: ['在下雨呢…', '雨滴涼涼的。'],
    snowCatch: ['接到雪花了！', '雪好漂亮…'],
    thunder: ['呀！打雷了！', '嗚哇！好大聲…', '雷、雷聲好可怕…']
  },
  en: {
    dance: ['♪ La la la~', "Let's dance! ♪", 'Feel the beat~ ♪'],
    idol: ['Miku Miku~ ♪', 'Cute Miku, as always!', 'Yay~ ☆'],
    think: ['Hmm……', 'Let me think…', 'What was it again…'],
    idea: ['Got it!', 'I know! ☆', 'Oh, of course!'],
    tidy: ['Twintails: perfect!', 'All neat ♪', "Hair is an idol's life!"],
    yawn: ['Hwaah~…', 'Getting sleepy…', 'Mm… break time?'],
    doze: ['Zzz…', 'Mm… leeks…', 'Fuu…'],
    wake: ["I-I wasn't asleep!", 'Huh? Did I doze off?', "I was NOT napping!"],
    sneezeWindUp: ['Ha… ha……', 'My nose tickles…'],
    sneeze: ['Achoo!', 'Ha-CHOO!'],
    cheer: ["Let's go!", 'Do your best today!', 'Fight-o!'],
    bored: ['Play with me~', "I'm bored…", 'Busy?'],
    shiver: ['S-so cold…', 'Wrap up warm…', 'Brr… my hands are icy.'],
    rainFeel: ["It's raining…", 'The rain feels cool.'],
    snowCatch: ['I caught a snowflake!', 'The snow is so pretty…'],
    thunder: ['Eek! Thunder!', 'Whoa! So loud…', "Th-thunder's scary…"]
  },
  ja: {
    dance: ['♪ ラララ～', '一緒に踊ろ！♪', 'ノってきた～♪'],
    idol: ['ミクミク～♪', '今日もかわいいミクだよ！', 'いぇーい☆'],
    think: ['うーん……', 'ちょっと考えさせて…', 'なんだっけ…'],
    idea: ['わかった！', 'ひらめいた！☆', 'なるほど！'],
    tidy: ['ツインテ、よし！', 'うん、きれいになった♪', '髪はアイドルの命！'],
    yawn: ['ふぁ～…', 'ちょっと眠くなってきた…', 'ん…休憩する？'],
    doze: ['すぅ…', 'ん…ネギ…', 'zzz…'],
    wake: ['ね、寝てないよ！', 'あれ？今寝てた？', 'い、居眠りなんてしてないもん！'],
    sneezeWindUp: ['は…は……', '鼻がむずむずする…'],
    sneeze: ['くしゅん！', 'はっくしゅん！'],
    cheer: ['がんばろー！', '今日もファイト！', 'いっくよー！'],
    bored: ['あそぼ～', 'ひまだなぁ…', '忙しい？'],
    shiver: ['さ、さむい…', 'あったかくしないと…', 'うぅ…手が冷たい。'],
    rainFeel: ['雨だね…', '雨、ひんやりする。'],
    snowCatch: ['雪、つかまえた！', '雪きれい…'],
    thunder: ['きゃっ！雷！', 'わっ！すごい音…', 'か、雷こわい…']
  }
};
