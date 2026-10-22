// When Miku sleeps.
//
// By default she sleeps from 1:00 to 7:00. The app can override that for a while: when you
// say good night she goes to bed early, when you wake her up (or say good morning) she stays
// up for a bit. The app keeps the override so both page layers (and the next launch) agree.

export const SLEEP_START = 1;
export const SLEEP_END = 7;

export function scheduledAsleep(hour, start = SLEEP_START, end = SLEEP_END) {
  if (!Number.isFinite(hour)) return false;
  const h = ((hour % 24) + 24) % 24;
  return start < end ? h >= start && h < end : h >= start || h < end;
}

/** { asleep, until } from the app, or null. Anything malformed is ignored. */
export function normalizeOverride(value) {
  if (!value || typeof value !== 'object') return null;
  const until = Number(value.until);
  if (typeof value.asleep !== 'boolean' || !Number.isFinite(until)) return null;
  return { asleep: value.asleep, until };
}

export function isAsleep({ hour, nowMs, override = null, start = SLEEP_START, end = SLEEP_END }) {
  const active = normalizeOverride(override);
  if (active && nowMs < active.until) return active.asleep;
  return scheduledAsleep(hour, start, end);
}

/**
 * The phases she goes through, so going to bed and getting up are never a jump cut:
 *   awake → windingDown (yawns, says good night) → dimming → lying
 *   lying → brightening → awake
 * dimming and brightening fade the character out, swap standing ↔ lying (and the scene)
 * while she's invisible, then fade her back in. Without a bed in the scene she only dozes.
 * `step` is called every frame; it returns the phase, whether she's lying in bed now and
 * how visible the character should be (0..1).
 */
export function createSleepCycle({ windDown = 3.6, fade = 0.7 } = {}) {
  let phase = 'awake';
  let since = 0;
  const swap = fade * 2;

  function enter(next, time) {
    phase = next;
    since = time;
  }

  function step({ time, wantAsleep, busy = false, canLie = true }) {
    const elapsed = time - since;
    switch (phase) {
      case 'awake':
        // Not while you're holding her or she's in the middle of reacting to you.
        if (wantAsleep && !busy) enter('windingDown', time);
        break;
      case 'windingDown':
        if (!wantAsleep) enter('awake', time);
        else if (elapsed >= windDown) enter(canLie ? 'dimming' : 'dozing', time);
        break;
      case 'dozing':
        if (!wantAsleep) enter('awake', time);
        else if (canLie) enter('dimming', time);
        break;
      case 'dimming':
        if (!canLie) enter(elapsed >= fade ? 'brightening' : 'dozing', time);
        else if (elapsed >= swap) enter('lying', time);
        break;
      case 'lying':
        if (!wantAsleep || !canLie) enter('brightening', time);
        break;
      case 'brightening':
        if (elapsed >= swap) enter(wantAsleep && !canLie ? 'dozing' : 'awake', time);
        break;
      default:
        enter('awake', time);
    }
    const local = time - since;
    const swapping = phase === 'dimming' || phase === 'brightening';
    const visibility = swapping ? Math.min(1, Math.abs(1 - 2 * Math.min(local, swap) / swap)) : 1;
    const secondHalf = local >= fade;
    const lying = phase === 'lying' || (phase === 'dimming' && secondHalf) || (phase === 'brightening' && !secondHalf);
    return { phase, since, visibility, lying };
  }

  return {
    step,
    get phase() { return phase; },
    reset(time = 0) { enter('awake', time); }
  };
}
