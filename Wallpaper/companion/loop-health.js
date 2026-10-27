// Is the animation loop healthy? Two different things look alike from inside the page:
//  - the system has paused frames (window covered, display asleep): a frame is requested but
//    not delivered. Restarting does nothing, so this is neither restarted nor reported;
//  - the loop has really stopped (nothing requested while visible): restart it, and report it
//    at most once per REPORT_INTERVAL so the diagnostics log isn't flooded.

export const REPORT_INTERVAL_MS = 10 * 60 * 1000;
export const NO_FRAMES_MS = 4000;

/**
 * @param {{ rafPending: boolean, lastFrameAt: number|null, now: number, lastReportAt: number|null }} state
 * @returns {{ restart: boolean, report: boolean, framesMissing: boolean }}
 */
export function checkLoop({ rafPending, lastFrameAt, now, lastReportAt }) {
  const framesMissing = lastFrameAt !== null && now - lastFrameAt > NO_FRAMES_MS;
  if (rafPending) return { restart: false, report: false, framesMissing };
  const report = lastReportAt === null || now - lastReportAt >= REPORT_INTERVAL_MS;
  return { restart: true, report, framesMissing };
}

/** One report per distinct error message per REPORT_INTERVAL. */
export function shouldReportError(lastReports, message, now) {
  const last = lastReports.get(message);
  if (last !== undefined && now - last < REPORT_INTERVAL_MS) return false;
  lastReports.set(message, now);
  if (lastReports.size > 20) lastReports.delete(lastReports.keys().next().value);
  return true;
}
