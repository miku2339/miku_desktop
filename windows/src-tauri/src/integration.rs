//! Coordinates native services and the shared character without giving pages host access.

use crate::{bridge, companion::Companion, layers, lock, Shell};
use serde_json::{json, Value};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Mutex,
};
use tauri::{AppHandle, Emitter, Manager};

pub struct Services {
    pub companion: Companion,
    pub environment: Mutex<Value>,
    pub voice_text: Mutex<String>,
    pub voice_active: AtomicBool,
    voice_job: Mutex<VoiceJob>,
    pub ui_owner: Mutex<Option<String>>,
    pub media_token: Mutex<Value>,
    pub call_media_gate: tokio::sync::Mutex<()>,
    pub stopped: AtomicBool,
    pub call_active: AtomicBool,
    pub listening: AtomicBool,
    pub chatting: AtomicBool,
    pub cancel_chat: tokio::sync::Notify,
}

impl Services {
    pub fn new(data_dir: std::path::PathBuf) -> Self {
        Self {
            companion: Companion::new(data_dir),
            environment: Mutex::new(json!({})),
            voice_text: Mutex::new(String::new()),
            voice_active: AtomicBool::new(false),
            voice_job: Mutex::new(VoiceJob::default()),
            ui_owner: Mutex::new(None),
            media_token: Mutex::new(Value::Null),
            call_media_gate: tokio::sync::Mutex::new(()),
            stopped: AtomicBool::new(false),
            call_active: AtomicBool::new(false),
            listening: AtomicBool::new(false),
            chatting: AtomicBool::new(false),
            cancel_chat: tokio::sync::Notify::new(),
        }
    }
}

pub fn broadcast(app: &AppHandle, function: &str, payload: &Value, background: bool) {
    for (label, window) in app.webview_windows() {
        if label.starts_with(layers::CHARACTER_PREFIX)
            || (background && label.starts_with(layers::BACKGROUND_PREFIX))
        {
            bridge::call_page(&window, function, payload);
        }
    }
}

pub fn notify(app: &AppHandle) {
    // Emit notifications only to trusted application pages, never to the wallpaper origin.
    for (label, window) in app.webview_windows() {
        if label.starts_with("app-") {
            let _ = window.emit("miku-changed", json!({}));
        }
    }
}

pub fn snapshot(app: &AppHandle) -> Value {
    snapshot_for(app, false)
}

pub fn snapshot_for(app: &AppHandle, include_songs: bool) -> Value {
    let services = app.state::<Services>();
    let mut value = services.companion.snapshot_for(include_songs);
    let shell = app.state::<Shell>();
    let legacy = lock(&shell.settings).clone();
    if let Some(settings) = value.get_mut("settings").and_then(Value::as_object_mut) {
        settings.insert("interactiveMode".into(), json!(legacy.interactive_mode));
        settings.insert("selectedScene".into(), json!(legacy.selected_scene));
        settings.insert("pinnedAnchor".into(), json!(legacy.pinned_anchor));
    }
    let mut environment = services.companion.environment();
    if let (Some(target), Some(cached)) = (
        environment.as_object_mut(),
        lock(&services.environment).as_object(),
    ) {
        target.extend(cached.clone());
    }
    value["environment"] = environment;
    value["capabilities"]["platform"] = crate::platform::snapshot()["capabilities"].clone();
    value
}

pub fn configure(app: &AppHandle) {
    let value = app.state::<Services>().companion.snapshot_for(false);
    let settings = &value["settings"];
    let language = settings
        .get("interfaceLanguage")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty() && *value != "auto")
        .unwrap_or("zh-Hant");
    broadcast(app, "setLanguage", &json!(language), false);
    let rotation = settings
        .get("sceneRotationSeconds")
        .and_then(Value::as_f64)
        .unwrap_or(180.);
    broadcast(
        app,
        "setRotationInterval",
        &json!(rotation.clamp(30., 3600.)),
        true,
    );
    let ambient = settings
        .get("ambientEnabled")
        .and_then(Value::as_bool)
        .unwrap_or(true);
    broadcast(app, "setAmbientEnabled", &json!(ambient), true);
    push_environment(app, &value);
}

pub fn push_environment(app: &AppHandle, value: &Value) {
    let environment = value.get("environment").unwrap_or(value);
    for (key, function, background) in [
        ("relationship", "setRelationship", false),
        ("sleep", "setSleep", true),
        ("specialDays", "setSpecialDays", false),
        ("weather", "setWeather", true),
        ("music", "setMusic", false),
    ] {
        if let Some(payload) = environment.get(key).filter(|value| !value.is_null()) {
            broadcast(app, function, payload, background);
        }
    }
    if let (Some(rise), Some(set)) = (
        environment["weather"]["sunrise"].as_f64(),
        environment["weather"]["sunset"].as_f64(),
    ) {
        for (_, window) in app
            .webview_windows()
            .into_iter()
            .filter(|(name, _)| name.starts_with("bg-") || name.starts_with("char-"))
        {
            bridge::eval_page(
                &window,
                &format!("window.mikuCompanion?.setSunTimes?.({rise},{set})"),
            );
        }
    }
}

#[derive(Default)]
struct VoiceJob {
    id: Option<u64>,
    started: bool,
}

impl VoiceJob {
    fn register(&mut self, id: u64) -> bool {
        if self.id == Some(id) {
            return false;
        }
        self.id = Some(id);
        self.started = false;
        true
    }
    fn start(&mut self, id: u64) -> bool {
        if self.id != Some(id) || self.started {
            return false;
        }
        self.started = true;
        true
    }
    fn stop(&mut self, id: u64) -> bool {
        if self.id != Some(id) {
            return false;
        }
        self.id = None;
        self.started = false;
        true
    }
}

fn voice_on_main(app: &AppHandle, action: impl FnOnce(&AppHandle) + Send + 'static) {
    let target = app.clone();
    let _ = app.run_on_main_thread(move || action(&target));
}

pub fn register_voice_job(app: &AppHandle, id: u64, text: &str) {
    let text = text.to_owned();
    voice_on_main(app, move |app| {
        // Native playback may have been replaced while its asynchronous caller was returning.
        if id < (1 << 40) && crate::platform::current_speech_job() != Some(id) {
            return;
        }
        let state = app.state::<Services>();
        if !lock(&state.voice_job).register(id) {
            return;
        }
        *lock(&state.voice_text) = text;
        if state.voice_active.swap(false, Ordering::SeqCst) {
            broadcast(app, "stopVoice", &Value::Null, false);
        }
    });
}

pub fn start_voice_job(app: &AppHandle, id: u64, payload: &Value) {
    let payload = payload.clone();
    voice_on_main(app, move |app| {
        let start = lock(&app.state::<Services>().voice_job).start(id);
        if start {
            emit_start_voice(app, &payload);
        }
    });
}

pub fn stop_voice_job(app: &AppHandle, id: u64) {
    voice_on_main(app, move |app| {
        let stop = lock(&app.state::<Services>().voice_job).stop(id);
        if stop {
            app.state::<Services>()
                .voice_active
                .store(false, Ordering::SeqCst);
            broadcast(app, "stopVoice", &Value::Null, false);
        }
    });
}

pub fn stop_untracked_voice(app: &AppHandle) {
    voice_on_main(app, move |app| {
        let untracked = lock(&app.state::<Services>().voice_job).id.is_none();
        if untracked {
            app.state::<Services>()
                .voice_active
                .store(false, Ordering::SeqCst);
            broadcast(app, "stopVoice", &Value::Null, false);
        }
    });
}

pub fn start_voice(app: &AppHandle, payload: &Value) {
    if let Some(id) = payload["jobId"].as_u64() {
        start_voice_job(app, id, payload);
        return;
    }
    let payload = payload.clone();
    voice_on_main(app, move |app| {
        *lock(&app.state::<Services>().voice_job) = VoiceJob::default();
        app.state::<Services>()
            .voice_active
            .store(false, Ordering::SeqCst);
        emit_start_voice(app, &payload);
    });
}

fn emit_start_voice(app: &AppHandle, payload: &Value) {
    let state = app.state::<Services>();
    if state.voice_active.swap(true, Ordering::SeqCst) {
        return;
    }
    let text = payload
        .get("text")
        .and_then(Value::as_str)
        .map(String::from)
        .unwrap_or_else(|| lock(&state.voice_text).clone());
    if let Some(duration) = payload
        .get("duration")
        .and_then(Value::as_f64)
        .filter(|value| value.is_finite() && *value > 0.)
    {
        broadcast(
            app,
            "startVoice",
            &json!({"text":text,"duration":duration.min(600.)}),
            false,
        );
    } else {
        broadcast(app, "startVoiceStream", &json!({"text":text}), false);
    }
}

pub fn stop_voice(app: &AppHandle) {
    voice_on_main(app, move |app| {
        *lock(&app.state::<Services>().voice_job) = VoiceJob::default();
        app.state::<Services>()
            .voice_active
            .store(false, Ordering::SeqCst);
        broadcast(app, "stopVoice", &Value::Null, false);
    });
}

pub fn stop(app: &AppHandle) {
    let services = app.state::<Services>();
    services.stopped.store(true, Ordering::SeqCst);
    services.cancel_chat.notify_waiters();
    let path = app.state::<Shell>().data_dir.clone();
    let _ = crate::platform::action("speech_stop", json!({}), &path);
    let _ = crate::platform::action("listen_stop", json!({}), &path);
    *lock(&services.media_token) = Value::Null;
    let _ = crate::platform::resume_paused_on_exit(&path);
}

#[cfg(test)]
mod voice_job_tests {
    use super::VoiceJob;
    #[test]
    fn replaced_voice_cannot_start_or_stop_current_mouth() {
        let mut voice = VoiceJob::default();
        assert!(voice.register(1));
        assert!(voice.start(1));
        assert!(voice.register(2));
        assert!(!voice.start(1));
        assert!(!voice.stop(1));
        assert!(voice.start(2));
        assert!(!voice.register(2));
        assert!(!voice.start(2));
        assert!(voice.stop(2));
    }
}
