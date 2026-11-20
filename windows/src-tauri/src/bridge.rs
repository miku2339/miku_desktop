//! Messages between the shared page and the shell.
//!
//! Page → shell: `bridge.js` calls `invoke('miku_message', { message })`; this mirrors
//! `WallpaperWindowController.userContentController(_:didReceive:)`.
//! Shell → page: `call_page` / `eval_page` run `window.mikuCompanion?.…` in the webview, like
//! Swift's `evaluate(...)` and `call(webView:function:payload:)`.

use serde_json::{Map, Value};
use tauri::{Manager, State, WebviewWindow};

use crate::passthrough::{self, NormRect};
use crate::{layers, lock, Shell};

#[tauri::command]
pub fn miku_message(window: WebviewWindow, shell: State<'_, Shell>, message: Value) {
    let Some(payload) = message.as_object() else { return };
    let Some(kind) = payload.get("type").and_then(Value::as_str) else { return };
    let label = window.label();

    match kind {
        "bounds" => {
            let Some(rect) = payload.get("rect").and_then(Value::as_object) else { return };
            let field = |name: &str| rect.get(name).and_then(Value::as_f64);
            let (Some(x), Some(y), Some(width), Some(height)) =
                (field("x"), field("y"), field("width"), field("height"))
            else {
                return;
            };
            if let Some(layer) = lock(&shell.layers).characters.get_mut(label) {
                layer.rect = Some(NormRect::clamped(x, y, width, height));
            }
        }
        "drag" => {
            let active = payload.get("active").and_then(Value::as_bool).unwrap_or(false);
            let take_mouse = {
                let mut layers = lock(&shell.layers);
                let Some(layer) = layers.characters.get_mut(label) else { return };
                layer.drag = active;
                active && layer.want_ignore(false)
            };
            if take_mouse {
                let _ = layers::set_character_passthrough(&window, false);
            }
        }
        "pin" => {
            let anchor = payload.get("x").and_then(Value::as_f64).filter(|x| x.is_finite());
            let mut settings = lock(&shell.settings);
            settings.pinned_anchor = anchor.map(|x| x.clamp(0.0, 1.0));
            settings.save(&shell.data_dir);
            drop(settings);
            crate::integration::notify(window.app_handle());
        }
        "touch" => {
            // Keep touch history and relationship state in sync with the shared character.
            let Some(touch) = payload.get("kind").and_then(Value::as_str) else { return };
            if touch.chars().count() > 24 {
                return;
            }
            let part = payload.get("part").and_then(Value::as_str).filter(|part| ["chest", "skirt"].contains(part));
            let mut entry = Map::new();
            entry.insert("what".into(), Value::from("touch"));
            entry.insert("kind".into(), Value::from(touch));
            if let Some(part) = part {
                entry.insert("part".into(), Value::from(part));
            }
            shell.diagnostics.log("shell", &entry);
            let app = window.app_handle();
            if let Some(services) = app.try_state::<crate::integration::Services>() {
                services.companion.record_touch(touch, part);
                crate::integration::configure(app);
                crate::integration::notify(app);
            }
        }
        "haptic" | "hover-haptic" => {
            // Trackpad haptics are macOS only; nothing to do on Windows.
        }
        "sleep" => {
            // Touch temporarily overrides the sleep schedule and updates both layers.
            if payload.get("asleep").and_then(Value::as_bool) != Some(false) {
                return;
            }
            let minutes = payload.get("minutes").and_then(Value::as_f64).unwrap_or(20.0).clamp(1.0, 120.0);
            let mut entry = Map::new();
            entry.insert("what".into(), Value::from("wake"));
            entry.insert("minutes".into(), Value::from(minutes));
            shell.diagnostics.log("shell", &entry);
            let app = window.app_handle();
            if let Some(services) = app.try_state::<crate::integration::Services>() {
                let _ = services.companion.action("wake", serde_json::json!({"minutes":minutes}));
                crate::integration::configure(app);
            }
        }
        "diag" => shell.diagnostics.log(label, payload),
        _ => {}
    }
}

/// The page's answer to a hit test sent by passthrough.rs.
#[tauri::command]
pub fn miku_hit_result(window: WebviewWindow, shell: State<'_, Shell>, seq: u64, zone: Option<String>) {
    let interactive = lock(&shell.settings).interactive_mode;
    let action = {
        let mut layers = lock(&shell.layers);
        let Some(layer) = layers.characters.get_mut(window.label()) else { return };
        passthrough::hit_result(layer, interactive, seq, zone.as_deref())
    };
    if let Some(passthrough::Action::SetIgnore(ignore)) = action {
        let _ = layers::set_character_passthrough(&window, ignore);
    }
}

/// `window.mikuCompanion?.<function>?.(<payload as JSON>)`
pub fn call_page(window: &WebviewWindow, function: &str, payload: &Value) {
    debug_assert!(function.chars().all(|c| c.is_ascii_alphanumeric()));
    eval_page(window, &format!("window.mikuCompanion?.{function}?.({payload})"));
}

pub fn eval_page(window: &WebviewWindow, script: &str) {
    if let Err(error) = window.eval(script) {
        let shell = window.state::<Shell>();
        shell.diagnostics.note("bridge", &format!("eval failed in {}: {error}", window.label()));
    }
}
