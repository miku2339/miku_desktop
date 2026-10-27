import test from 'node:test';
import assert from 'node:assert/strict';
import { checkLoop, REPORT_INTERVAL_MS, shouldReportError } from '../Wallpaper/companion/loop-health.js';

test('frames paused by the system are neither restarted nor reported', () => {
  const result = checkLoop({ rafPending: true, lastFrameAt: 0, now: 600_000, lastReportAt: null });
  assert.deepEqual(result, { restart: false, report: false, framesMissing: true });
});

test('a healthy loop is left alone', () => {
  const result = checkLoop({ rafPending: true, lastFrameAt: 9_900, now: 10_000, lastReportAt: null });
  assert.deepEqual(result, { restart: false, report: false, framesMissing: false });
});

test('a loop that really stopped is restarted and reported once', () => {
  const first = checkLoop({ rafPending: false, lastFrameAt: 0, now: 5_000, lastReportAt: null });
  assert.equal(first.restart, true);
  assert.equal(first.report, true);
  const soon = checkLoop({ rafPending: false, lastFrameAt: 0, now: 7_000, lastReportAt: 5_000 });
  assert.equal(soon.restart, true, 'it is still restarted');
  assert.equal(soon.report, false, 'but not reported again within ten minutes');
  const later = checkLoop({ rafPending: false, lastFrameAt: 0, now: 5_000 + REPORT_INTERVAL_MS, lastReportAt: 5_000 });
  assert.equal(later.report, true, 'ten minutes later it may be reported again');
});

test('the same rendering error is reported once per ten minutes', () => {
  const reports = new Map();
  assert.equal(shouldReportError(reports, 'boom', 0), true);
  assert.equal(shouldReportError(reports, 'boom', 1_000), false);
  assert.equal(shouldReportError(reports, 'other', 1_000), true);
  assert.equal(shouldReportError(reports, 'boom', REPORT_INTERVAL_MS), true);
});

test('the error memory stays small', () => {
  const reports = new Map();
  for (let index = 0; index < 50; index++) shouldReportError(reports, `error ${index}`, index);
  assert.ok(reports.size <= 21);
});
