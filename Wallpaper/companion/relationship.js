// How Miku feels about you, mirrored from the app's memory.
//
// The app owns the real numbers (they persist across launches); the page keeps a copy so
// reactions can change straight away, before the app has answered.
//
// friendship 0–100: it grows with chatting, head pats and holding hands, and drops when
// you're rough with her. It only ever means friendship: closer friends get warmer, more
// relaxed lines, never romance.
//
// offended: she's been touched where she doesn't want to be touched. Until you apologise
// in the chat she keeps her distance: she turns half away, brushes off head pats and hand
// holding, and isn't in the mood to dance or chat.

export const RELATIONSHIP_TOUCH_KINDS = new Set([
  'headPat', 'headStroke', 'handHold', 'poke', 'wave', 'hello', 'carry', 'dizzy', 'sulk', 'ouch', 'boundary'
]);

// Touches she'd brush off while she's upset with you.
const SNUBBED = new Set(['headPat', 'headStroke', 'handHold', 'poke', 'wave', 'hello']);

const clamp = (value, minimum, maximum) => Math.min(maximum, Math.max(minimum, value));

export function friendshipLevel(friendship) {
  if (friendship >= 75) return 3;
  if (friendship >= 50) return 2;
  if (friendship >= 25) return 1;
  return 0;
}

export function createRelationship({ friendship = 30 } = {}) {
  const data = {
    friendship: clamp(friendship, 0, 100),
    level: friendshipLevel(friendship),
    offended: false,
    strikesToday: 0,
    synced: false
  };

  /** Apply what the app remembers. Returns whether she has just forgiven you. */
  function set(payload = {}) {
    if (!payload || typeof payload !== 'object') return { forgiven: false };
    const wasOffended = data.offended;
    const value = Number(payload.friendship);
    if (Number.isFinite(value)) data.friendship = clamp(value, 0, 100);
    if (typeof payload.offended === 'boolean') data.offended = payload.offended;
    const strikes = Number(payload.strikesToday);
    if (Number.isFinite(strikes)) data.strikesToday = clamp(Math.round(strikes), 0, 99);
    data.level = friendshipLevel(data.friendship);
    data.synced = true;
    return { forgiven: wasOffended && !data.offended };
  }

  /**
   * She's been touched on the chest. Returns how she reacts:
   *  - 'angry': you're not close; she's cross and tells you off.
   *  - 'hurt': you're friends; she's disappointed in you rather than just angry.
   *  - 'again': you did it again while she was already upset; she turns her back on you.
   */
  function noteBoundary() {
    const again = data.offended;
    const closeFriends = data.level >= 2;
    data.offended = true;
    data.strikesToday += 1;
    data.friendship = clamp(data.friendship - (again ? 12 : 8), 0, 100);
    data.level = friendshipLevel(data.friendship);
    return { style: again ? 'again' : closeFriends ? 'hurt' : 'angry', strikes: data.strikesToday };
  }

  /** Local guess at the friendship change, until the app sends the real value. */
  function noteTouch(kind) {
    const change = {
      headPat: 0.3, headStroke: 0.3, handHold: 0.4, wave: 0.15, hello: 0.15, poke: 0.05,
      dizzy: -1.5, sulk: -3, ouch: -0.5
    }[kind] ?? 0;
    if (data.offended && change > 0) return;
    data.friendship = clamp(data.friendship + change, 0, 100);
    data.level = friendshipLevel(data.friendship);
  }

  /** Whether she brushes this touch off right now. */
  const snubs = kind => data.offended && SNUBBED.has(kind);

  /**
   * Which phrase list fits a touch: brushed off while she's upset, a bit reserved when
   * you aren't close, and teasing only once you're good friends.
   */
  function phraseKey(kind, { teased = false } = {}) {
    if (snubs(kind) || (data.offended && kind === 'carry')) return 'snub';
    if (data.level === 0 && ['headStroke', 'handHold', 'poke', 'carry'].includes(kind)) return `${kind}Distant`;
    if (teased && data.level >= 2 && kind !== 'carry') return 'teased';
    return kind;
  }

  return {
    set,
    noteBoundary,
    noteTouch,
    snubs,
    phraseKey,
    get friendship() { return data.friendship; },
    get level() { return data.level; },
    get offended() { return data.offended; },
    get strikesToday() { return data.strikesToday; },
    snapshot: () => ({ ...data })
  };
}
