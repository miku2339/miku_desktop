//! Click-through for the character layer, following `WallpaperWindowController.updateMousePassthrough`.
//!
//! The window ignores the mouse (`WS_EX_TRANSPARENT | WS_EX_LAYERED`, set by Tauri's
//! `set_ignore_cursor_events`) except while the cursor is over Miku herself. Every 1/30 s:
//! the page's `bounds` box says the cursor is *near* her; then the page raycasts against the
//! model (`window.mikuCompanion.hitTest(x, y)`) so the transparent space around her stays
//! clickable for the desktop and other windows.
//!
//! `webview.eval` returns nothing, so the hit-test script answers through the
//! `miku_hit_result` command (bridge.rs) with the sequence number it was sent.

use std::time::{Duration, Instant};

pub const POLL_INTERVAL: Duration = Duration::from_millis(33);
/// A hit test that never answered (page busy or reloading) is dropped after this.
pub const HIT_TIMEOUT: Duration = Duration::from_millis(500);
const REFRESH_INTERVAL: Duration = Duration::from_millis(250);
const MIN_MOVE: f64 = 0.0008;

/// A window's place on the virtual desktop, in physical pixels.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Frame {
    pub x: i32,
    pub y: i32,
    pub width: u32,
    pub height: u32,
}

impl Frame {
    /// The cursor as 0…1 across the window, top-left origin (the page's coordinates).
    pub fn normalized(&self, (cx, cy): (f64, f64)) -> Option<(f64, f64)> {
        if self.width == 0 || self.height == 0 {
            return None;
        }
        let (x, y) = (self.x as f64, self.y as f64);
        let (w, h) = (self.width as f64, self.height as f64);
        if cx < x || cy < y || cx >= x + w || cy >= y + h {
            return None;
        }
        Some(((cx - x) / w, (cy - y) / h))
    }
}

/// Miku's bounding box from the page's `bounds` message, 0…1 across the window.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct NormRect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl NormRect {
    pub fn clamped(x: f64, y: f64, width: f64, height: f64) -> Self {
        let unit = |v: f64| if v.is_finite() { v.clamp(0.0, 1.0) } else { 0.0 };
        Self { x: unit(x), y: unit(y), width: unit(width), height: unit(height) }
    }

    fn is_empty(&self) -> bool {
        self.width <= 0.0 || self.height <= 0.0
    }

    /// Contains the point, with the box grown by `margin` on every side.
    fn contains_with_margin(&self, (px, py): (f64, f64), margin: f64) -> bool {
        px >= self.x - margin
            && py >= self.y - margin
            && px <= self.x + self.width + margin
            && py <= self.y + self.height + margin
    }
}

/// Per character window state (one per monitor).
#[derive(Debug)]
pub struct CharacterLayer {
    pub frame: Frame,
    pub ready: bool,
    pub rect: Option<NormRect>,
    pub drag: bool,
    /// What was last applied with `set_ignore_cursor_events`; `None` before the first call.
    pub ignoring: Option<bool>,
    pub in_flight: Option<(u64, Instant)>,
    pub last_point: Option<(f64, f64)>,
    pub last_time: Option<Instant>,
    pub hovering: bool,
}

impl CharacterLayer {
    pub fn new(frame: Frame) -> Self {
        Self {
            frame,
            ready: false,
            rect: None,
            drag: false,
            ignoring: Some(true),
            in_flight: None,
            last_point: None,
            last_time: None,
            hovering: false,
        }
    }

    /// The page reloaded: forget everything it told us.
    pub fn reset(&mut self) {
        *self = Self { ignoring: self.ignoring, ..Self::new(self.frame) };
    }

    /// Records the wanted pass-through state; true when the window must be told.
    pub fn want_ignore(&mut self, ignore: bool) -> bool {
        if self.ignoring == Some(ignore) {
            return false;
        }
        self.ignoring = Some(ignore);
        true
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum Action {
    SetIgnore(bool),
    EndHover,
    HitTest { seq: u64, x: f64, y: f64 },
}

/// One polling step for one character window. `cursor` is in physical desktop pixels.
pub fn decide(
    layer: &mut CharacterLayer,
    interactive: bool,
    cursor: Option<(f64, f64)>,
    now: Instant,
    next_seq: &mut u64,
) -> Vec<Action> {
    let mut actions = Vec::new();
    let rect = layer.rect.filter(|rect| !rect.is_empty());
    let Some(rect) = rect.filter(|_| interactive && layer.ready) else {
        pass_through(layer, &mut actions);
        return actions;
    };
    if layer.drag {
        // Keep receiving events while she is being dragged, even if the cursor outruns her.
        if layer.want_ignore(false) {
            actions.push(Action::SetIgnore(false));
        }
        return actions;
    }
    let point = cursor.and_then(|cursor| layer.frame.normalized(cursor));
    let Some(point) = point.filter(|point| rect.contains_with_margin(*point, 0.01)) else {
        layer.last_point = None;
        pass_through(layer, &mut actions);
        return actions;
    };

    if let Some((_, sent)) = layer.in_flight {
        if now.duration_since(sent) < HIT_TIMEOUT {
            return actions;
        }
        layer.in_flight = None;
    }
    let moved = layer
        .last_point
        .map_or(true, |(x, y)| (x - point.0).hypot(y - point.1) > MIN_MOVE);
    let stale = layer.last_time.map_or(true, |time| now.duration_since(time) > REFRESH_INTERVAL);
    if !moved && !stale {
        return actions;
    }
    *next_seq += 1;
    layer.in_flight = Some((*next_seq, now));
    layer.last_point = Some(point);
    layer.last_time = Some(now);
    actions.push(Action::HitTest { seq: *next_seq, x: point.0, y: point.1 });
    actions
}

/// The page's answer to hit test `seq`: a body zone ("head", "hand", "body"…) or nothing.
pub fn hit_result(layer: &mut CharacterLayer, interactive: bool, seq: u64, zone: Option<&str>) -> Option<Action> {
    if layer.in_flight.map(|(sent, _)| sent) != Some(seq) {
        return None;
    }
    layer.in_flight = None;
    if layer.drag || !layer.ready {
        return None;
    }
    let hit = interactive && zone.is_some();
    layer.hovering = hit;
    layer.want_ignore(!hit).then_some(Action::SetIgnore(!hit))
}

fn pass_through(layer: &mut CharacterLayer, actions: &mut Vec<Action>) {
    if layer.want_ignore(true) {
        actions.push(Action::SetIgnore(true));
    }
    // The cursor left her without a final hit test (e.g. it left her bounding box).
    if layer.hovering {
        layer.hovering = false;
        if layer.ready {
            actions.push(Action::EndHover);
        }
    }
}

/// The script sent for one hit test; it reports back through `miku_hit_result`.
pub fn hit_test_script(seq: u64, x: f64, y: f64) -> String {
    format!(
        "(() => {{ let zone = null; try {{ const r = window.mikuCompanion?.hitTest({x:.5}, {y:.5}) ?? false; \
         zone = typeof r === 'string' ? r : (r === true ? 'body' : null); }} catch (_) {{}} \
         window.__TAURI_INTERNALS__?.invoke('miku_hit_result', {{ seq: {seq}, zone }}); }})()"
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    const FRAME: Frame = Frame { x: 1920, y: 0, width: 1000, height: 500 };

    fn ready_layer() -> CharacterLayer {
        let mut layer = CharacterLayer::new(FRAME);
        layer.ready = true;
        layer.rect = Some(NormRect::clamped(0.4, 0.2, 0.2, 0.6));
        layer
    }

    #[test]
    fn normalizes_against_a_secondary_monitor() {
        assert_eq!(FRAME.normalized((2420.0, 250.0)), Some((0.5, 0.5)));
        assert_eq!(FRAME.normalized((100.0, 250.0)), None);
    }

    #[test]
    fn passes_through_until_ready_and_interactive() {
        let mut seq = 0;
        let mut layer = CharacterLayer::new(FRAME);
        layer.ignoring = None;
        let actions = decide(&mut layer, true, Some((2420.0, 250.0)), Instant::now(), &mut seq);
        assert_eq!(actions, vec![Action::SetIgnore(true)]);

        let mut layer = ready_layer();
        layer.ignoring = Some(false);
        let actions = decide(&mut layer, false, Some((2420.0, 250.0)), Instant::now(), &mut seq);
        assert_eq!(actions, vec![Action::SetIgnore(true)]);
    }

    #[test]
    fn hit_tests_near_her_and_takes_the_mouse_on_a_hit() {
        let mut seq = 0;
        let mut layer = ready_layer();
        let now = Instant::now();
        let actions = decide(&mut layer, true, Some((2420.0, 250.0)), now, &mut seq);
        assert_eq!(actions, vec![Action::HitTest { seq: 1, x: 0.5, y: 0.5 }]);
        // One hit test at a time.
        assert!(decide(&mut layer, true, Some((2421.0, 250.0)), now, &mut seq).is_empty());

        assert_eq!(hit_result(&mut layer, true, 1, Some("head")), Some(Action::SetIgnore(false)));
        assert!(layer.hovering);
        // A stale answer is ignored.
        assert_eq!(hit_result(&mut layer, true, 1, None), None);
    }

    #[test]
    fn leaving_her_box_passes_through_and_ends_hover() {
        let mut seq = 0;
        let mut layer = ready_layer();
        layer.hovering = true;
        layer.ignoring = Some(false);
        let actions = decide(&mut layer, true, Some((1950.0, 10.0)), Instant::now(), &mut seq);
        assert_eq!(actions, vec![Action::SetIgnore(true), Action::EndHover]);
    }

    #[test]
    fn dragging_keeps_the_mouse() {
        let mut seq = 0;
        let mut layer = ready_layer();
        layer.drag = true;
        let actions = decide(&mut layer, true, Some((0.0, 0.0)), Instant::now(), &mut seq);
        assert_eq!(actions, vec![Action::SetIgnore(false)]);
    }

    #[test]
    fn retries_after_an_unanswered_hit_test() {
        let mut seq = 0;
        let mut layer = ready_layer();
        let start = Instant::now();
        decide(&mut layer, true, Some((2420.0, 250.0)), start, &mut seq);
        let later = start + HIT_TIMEOUT + Duration::from_millis(1);
        let actions = decide(&mut layer, true, Some((2420.0, 250.0)), later, &mut seq);
        assert_eq!(actions, vec![Action::HitTest { seq: 2, x: 0.5, y: 0.5 }]);
    }

    #[test]
    fn hit_test_script_reports_back() {
        let script = hit_test_script(7, 0.25, 0.5);
        assert!(script.contains("hitTest(0.25000, 0.50000)"));
        assert!(script.contains("invoke('miku_hit_result', { seq: 7, zone })"));
    }
}
