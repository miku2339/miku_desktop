// Mouth timing for a line she says. Two sources:
//  - text only (a bubble with no voice): about seven characters a second, capped at 8 s;
//  - a voiced reply: the mouth starts when the audio starts and its length follows the audio,
//    with the characters spread evenly over it.
// Commas and full stops close the mouth either way.

export const MOUTH_VOWELS = ['あ', 'い', 'う', 'え', 'お'];
export const PAUSE = /[\s、。，．,.!?！？…〜～ー・「」『』（）()♪☆★♥~\-]/;

/** Longest a voiced line may drive the mouth, as a guard against a bad duration. */
export const MAX_VOICE_SECONDS = 120;
/** A voiced reply whose audio fails this soon after the bubble falls back to text timing. */
export const VOICE_FALLBACK_WINDOW = 2.5;

const isLatinOnly = text => /[A-Za-z]/.test(text) && !/[぀-ヿ一-鿿]/.test(text);

/** Text-only timing, used for bubbles that are never read aloud. */
export function textTalk(text, start) {
  const chars = [...String(text ?? '')];
  if (!chars.length || !Number.isFinite(start)) return null;
  const rate = isLatinOnly(text) ? 14 : 7.5;
  return { chars, rate, start, end: start + Math.min(8, chars.length / rate), voiced: false };
}

/** Timing for audio that has just started playing and lasts `duration` seconds. */
export function voiceTalk(text, start, duration) {
  const chars = [...String(text ?? '')];
  const seconds = Number(duration);
  if (!chars.length || !Number.isFinite(start) || !Number.isFinite(seconds) || seconds <= 0) return null;
  const length = Math.min(MAX_VOICE_SECONDS, seconds);
  return { chars, rate: chars.length / length, start, end: start + length, voiced: true };
}

/** The player starts and pauses this timing as streamed audio becomes audible. */
export function streamTalk(text, start) {
  const chars = [...String(text ?? '')];
  if (!chars.length || !Number.isFinite(start)) return null;
  return { chars, rate: isLatinOnly(text) ? 14 : 7.5, start,
    end: start + MAX_VOICE_SECONDS, voiced: true, streaming: true };
}

/**
 * Mouth shape at `elapsed`: null when the line is over (the caller drops it), otherwise
 * { vowel, open } with open 0 while paused on punctuation.
 */
export function talkFrame(talk, elapsed) {
  if (!talk || !Number.isFinite(elapsed)) return null;
  if (elapsed < talk.start || elapsed > talk.end + 0.15) return null;
  if (elapsed > talk.end) return { vowel: null, open: 0 };
  const position = Math.floor((elapsed - talk.start) * talk.rate);
  const index = talk.streaming ? position % talk.chars.length : Math.min(talk.chars.length - 1, position);
  const char = talk.chars[index] ?? '';
  if (!char || PAUSE.test(char)) return { vowel: null, open: 0 };
  const syllable = (elapsed - talk.start) * 7;
  const open = Math.sin((syllable % 1) * Math.PI);
  const vowel = MOUTH_VOWELS[(char.codePointAt(0) + Math.floor(syllable)) % MOUTH_VOWELS.length];
  return { vowel, open };
}

/** Whether a voice failure is still close enough to the bubble to move the mouth from text. */
export function shouldFallBack(pending, elapsed) {
  return Boolean(pending) && Number.isFinite(elapsed) && elapsed - pending.at >= 0
    && elapsed - pending.at <= VOICE_FALLBACK_WINDOW;
}
