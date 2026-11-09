//! Time, privacy-gated observation and proactive delivery run independently of the UI.

use crate::{
    bridge, commands,
    integration::{self, Services},
    layers, lock, platform, Shell,
};
use chrono::{DateTime, Local, NaiveTime};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::atomic::Ordering;
use std::time::{Duration, Instant};
use tauri::{AppHandle, Manager};

fn enabled(settings: &Value, key: &str, alias: &str) -> bool {
    settings[key]
        .as_bool()
        .or_else(|| settings[alias].as_bool())
        .unwrap_or(false)
}

pub fn context(settings: &Value, cached: &Value) -> Value {
    let mut value = cached.clone();
    if !value.is_object() {
        value = json!({});
    }
    let shares = settings["aiProvider"] != "cloud" || settings["cloudSharesAwareness"] == true;
    if !shares || !enabled(settings, "awarenessEnabled", "awarenessActivity") {
        value["foreground"] = Value::Null;
    }
    if !shares || !enabled(settings, "mediaAwarenessEnabled", "awarenessMedia") {
        value["media"] = Value::Null;
        value["music"] = Value::Null;
    }
    if !shares || !enabled(settings, "screenAwarenessEnabled", "awarenessScreen") {
        value["screen"] = Value::Null;
    }
    value.as_object_mut().unwrap().remove("platform");
    if let Some(weather) = value["weather"].as_object_mut() {
        weather.remove("latitude");
        weather.remove("longitude");
    }
    value["time"] = json!(Local::now().to_rfc3339());
    value
}

fn quiet_hours(settings: &Value, now: NaiveTime) -> bool {
    if settings["speechQuietEnabled"] == false {
        return false;
    }
    let parse = |key: &str| {
        settings[key]
            .as_str()
            .and_then(|value| NaiveTime::parse_from_str(value, "%H:%M").ok())
    };
    let (Some(start), Some(end)) = (parse("quietStart"), parse("quietEnd")) else {
        return false;
    };
    if start == end {
        false
    } else if start < end {
        now >= start && now < end
    } else {
        now >= start || now < end
    }
}

fn inhibited(settings: &Value, cached: &Value, asleep: bool, busy: bool, now: NaiveTime) -> bool {
    busy || asleep
        || settings["muted"] == true
        || settings["speechMuted"] == true
        || quiet_hours(settings, now)
        || ["quiet", "fullscreen", "locked", "sleeping"]
            .iter()
            .any(|key| cached[*key] == true)
}

fn blocked(app: &AppHandle, include_voice: bool) -> bool {
    let services = app.state::<Services>();
    let busy = services.stopped.load(Ordering::SeqCst)
        || services.call_active.load(Ordering::SeqCst)
        || services.listening.load(Ordering::SeqCst)
        || services.chatting.load(Ordering::SeqCst)
        || (include_voice && services.voice_active.load(Ordering::SeqCst));
    let settings = services.companion.settings();
    let cached = lock(&services.environment).clone();
    inhibited(
        &settings,
        &cached,
        services.companion.environment()["sleep"]["asleep"] == true,
        busy,
        Local::now().time(),
    )
}

fn music_status(media: &Value) -> Value {
    let session = media.get("session").unwrap_or(media);
    let title = session["title"].as_str().unwrap_or("");
    let playing =
        !title.is_empty() && (session["status"] == "Playing" || session["playing"] == true);
    json!({"playing":playing,"title":title,"artist":session["artist"]})
}

async fn native(app: &AppHandle, action: &str, payload: Value) -> Result<Value, String> {
    let path = app.state::<Shell>().data_dir.clone();
    let action = action.to_owned();
    tauri::async_runtime::spawn_blocking(move || platform::action(&action, payload, &path))
        .await
        .map_err(|_| "原生服務已中止".to_string())?
}

async fn speak_proactive(app: &AppHandle, text: &str, language: &str) {
    if blocked(app, true) {
        return;
    }
    let settings = app.state::<Services>().companion.settings();
    if settings["speechEnabled"] != true
        || settings["readChatOnly"]
            .as_bool()
            .or_else(|| settings["speechRepliesOnly"].as_bool())
            .unwrap_or(true)
        || !commands::speech_allowed(app, &settings)
    {
        return;
    }
    let Ok(job) = commands::speak_background(app, text, language).await else {
        return;
    };
    let Some(id) = job["jobId"].as_u64() else {
        return;
    };
    integration::register_voice_job(app, id, text);
    let deadline = Instant::now() + Duration::from_secs(600);
    loop {
        let settings = app.state::<Services>().companion.settings();
        let stopped = blocked(app, false)
            || settings["speechEnabled"] != true
            || settings["readChatOnly"]
                .as_bool()
                .or_else(|| settings["speechRepliesOnly"].as_bool())
                .unwrap_or(true)
            || !commands::speech_allowed(app, &settings)
            || Instant::now() >= deadline;
        if stopped {
            let _ = native(app, "speech_stop", json!({"jobId":id})).await;
            break;
        }
        match native(app, "speak_status", json!({"jobId":id})).await {
            Ok(status) if status["state"] == "speaking" => {
                integration::start_voice_job(app, id, &json!({"text":text}))
            }
            Ok(status) if status["state"] == "starting" => {}
            _ => break,
        }
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
    integration::stop_voice_job(app, id);
}

fn diary_days(now: DateTime<Local>, asleep: bool, entries: &Value) -> Vec<String> {
    let day = |at: DateTime<Local>| {
        (at - chrono::Duration::hours(5))
            .format("%Y-%m-%d")
            .to_string()
    };
    let mut days = vec![day(now - chrono::Duration::hours(24))];
    if asleep {
        days.push(day(now));
    }
    days.retain(|day| {
        !entries.as_array().into_iter().flatten().any(|entry| {
            entry["day"].as_str().or_else(|| entry["id"].as_str()) == Some(day.as_str())
        })
    });
    days
}

fn start_diary(app: AppHandle) {
    tauri::async_runtime::spawn(async move {
        let mut periodic = Instant::now() + Duration::from_secs(30);
        let mut bedtime = None;
        let mut previous_sleep: Option<bool> = None;
        let mut failures: HashMap<String, u8> = HashMap::new();
        loop {
            tokio::time::sleep(Duration::from_secs(5)).await;
            let services = app.state::<Services>();
            if services.stopped.load(Ordering::SeqCst) {
                break;
            }
            let asleep = services.companion.environment()["sleep"]["asleep"] == true;
            if previous_sleep.is_some_and(|previous| !previous && asleep) {
                bedtime = Some(Instant::now() + Duration::from_secs(20));
            }
            previous_sleep = Some(asleep);
            if Instant::now() < periodic && !bedtime.is_some_and(|due| Instant::now() >= due) {
                continue;
            }
            if services.chatting.load(Ordering::SeqCst)
                || services.call_active.load(Ordering::SeqCst)
                || services.listening.load(Ordering::SeqCst)
            {
                continue;
            }
            periodic = Instant::now() + Duration::from_secs(600);
            bedtime = None;
            if services.companion.settings()["memoryEnabled"] == false {
                continue;
            }
            let snapshot = services.companion.snapshot_for(false);
            let candidates = diary_days(Local::now(), asleep, &snapshot["diary"]);
            failures.retain(|day, _| candidates.contains(day));
            for day in candidates {
                if failures.get(&day).copied().unwrap_or(0) >= 3 {
                    continue;
                }
                match services
                    .companion
                    .remote_action("diary_generate", json!({"day":day}))
                    .await
                {
                    Ok(_) => integration::notify(&app),
                    Err(_) => {
                        *failures.entry(day).or_default() += 1;
                    }
                }
                break;
            }
        }
    });
}

pub fn start(app: AppHandle) {
    start_diary(app.clone());
    let fast = app.clone();
    tauri::async_runtime::spawn(async move {
        let mut hidden = false;
        let mut last = Value::Null;
        loop {
            let services = fast.state::<Services>();
            if services.stopped.load(Ordering::SeqCst) {
                break;
            }
            let system = platform::snapshot();
            {
                let mut cache = lock(&services.environment);
                cache["platform"] = system.clone();
                for (target, source) in [
                    ("quiet", "quiet"),
                    ("fullscreen", "fullscreen"),
                    ("locked", "sessionLocked"),
                    ("idleSeconds", "idleSeconds"),
                ] {
                    cache[target] = system[source].clone();
                }
                cache["sleeping"] = json!(
                    system["sleepState"] == "suspended" || system["displaySleepState"] == "off"
                );
            }
            let should_hide = system["fullscreen"] == true
                || system["sessionLocked"] == true
                || system["displaySleepState"] == "off"
                || system["sleepState"] == "suspended";
            if hidden != should_hide || should_hide {
                let was_hidden = hidden;
                hidden = should_hide;
                for window in layers::character_windows(&fast) {
                    if hidden {
                        bridge::call_page(&window, "setInteractive", &json!(false));
                        if window.is_visible().unwrap_or(false) {
                            let _ = window.hide();
                        }
                    } else if was_hidden {
                        let interactive = lock(&fast.state::<Shell>().settings).interactive_mode;
                        bridge::call_page(&window, "setInteractive", &json!(interactive));
                        let _ = window.show();
                        let _ = layers::set_character_passthrough(&window, true);
                        if let Some(layer) = lock(&fast.state::<Shell>().layers)
                            .characters
                            .get_mut(window.label())
                        {
                            layer.ignoring = Some(true);
                            layer.drag = false;
                        }
                    }
                }
            }
            let mut environment = services.companion.environment();
            let cache = lock(&services.environment).clone();
            for key in ["weather", "music"] {
                if let Some(value) = cache.get(key) {
                    environment[key] = value.clone();
                }
            }
            if environment != last {
                integration::push_environment(&fast, &environment);
                integration::notify(&fast);
                last = environment;
            }
            tokio::time::sleep(Duration::from_secs(2)).await;
        }
    });

    let observation = app.clone();
    tauri::async_runtime::spawn(async move {
        loop {
            let services = observation.state::<Services>();
            if services.stopped.load(Ordering::SeqCst) {
                break;
            }
            let settings = services.companion.settings();
            let activity = enabled(&settings, "awarenessEnabled", "awarenessActivity");
            let media = enabled(&settings, "mediaAwarenessEnabled", "awarenessMedia");
            let value = if activity || media {
                native(
                    &observation,
                    "awareness",
                    json!({"activityEnabled":activity,"mediaEnabled":media}),
                )
                .await
                .ok()
            } else {
                None
            };
            let current = services.companion.settings();
            {
                let mut cache = lock(&services.environment);
                cache["foreground"] = if enabled(&current, "awarenessEnabled", "awarenessActivity")
                {
                    value
                        .as_ref()
                        .map(|value| value["foreground"].clone())
                        .unwrap_or(Value::Null)
                } else {
                    Value::Null
                };
                cache["media"] = if enabled(&current, "mediaAwarenessEnabled", "awarenessMedia") {
                    value
                        .as_ref()
                        .map(|value| value["media"].clone())
                        .unwrap_or(Value::Null)
                } else {
                    Value::Null
                };
                cache["music"] = music_status(&cache["media"]);
            }
            tokio::time::sleep(Duration::from_secs(15)).await;
        }
    });

    let weather = app.clone();
    tauri::async_runtime::spawn(async move {
        loop {
            if weather.state::<Services>().stopped.load(Ordering::SeqCst) {
                break;
            }
            let settings = weather.state::<Services>().companion.settings();
            if let (Some(latitude), Some(longitude)) = (
                settings["latitude"].as_f64(),
                settings["longitude"].as_f64(),
            ) {
                if let Ok(value) = native(
                    &weather,
                    "weather",
                    json!({"latitude":latitude,"longitude":longitude}),
                )
                .await
                {
                    let current = weather.state::<Services>().companion.settings();
                    if current["latitude"] == settings["latitude"]
                        && current["longitude"] == settings["longitude"]
                    {
                        lock(&weather.state::<Services>().environment)["weather"] = value;
                    }
                }
            }
            tokio::time::sleep(Duration::from_secs(1800)).await;
        }
    });

    let screen = app.clone();
    tauri::async_runtime::spawn(async move {
        loop {
            tokio::time::sleep(Duration::from_secs(300)).await;
            let services = screen.state::<Services>();
            if services.stopped.load(Ordering::SeqCst) {
                break;
            }
            let settings = services.companion.settings();
            if !enabled(&settings, "screenAwarenessEnabled", "awarenessScreen")
                || (settings["aiProvider"] == "cloud" && settings["cloudSharesAwareness"] != true)
                || blocked(&screen, true)
            {
                continue;
            }
            if let Ok(capture) = native(
                &screen,
                "capture_screen",
                json!({"screenAwarenessEnabled":true}),
            )
            .await
            {
                let settings = services.companion.settings();
                if !enabled(&settings, "screenAwarenessEnabled", "awarenessScreen")
                    || (settings["aiProvider"] == "cloud"
                        && settings["cloudSharesAwareness"] != true)
                    || blocked(&screen, true)
                {
                    continue;
                }
                if let Some(image) = capture["dataURL"].as_str() {
                    let cached = lock(&services.environment).clone();
                    if let Ok(Some(description)) = services
                        .companion
                        .observe_screen(image.into(), context(&settings, &cached))
                        .await
                    {
                        let current = services.companion.settings();
                        if enabled(&current, "screenAwarenessEnabled", "awarenessScreen")
                            && (current["aiProvider"] != "cloud"
                                || current["cloudSharesAwareness"] == true)
                        {
                            lock(&services.environment)["screen"] = description;
                        }
                    }
                }
            }
        }
    });

    tauri::async_runtime::spawn(async move {
        loop {
            tokio::time::sleep(Duration::from_secs(60)).await;
            let services = app.state::<Services>();
            if services.stopped.load(Ordering::SeqCst) {
                break;
            }
            if blocked(&app, true) {
                continue;
            }
            let settings = services.companion.settings();
            let cached = lock(&services.environment).clone();
            let current = context(&settings, &cached);
            if let Ok(Some(mut reply)) = services.companion.proactive(current).await {
                if blocked(&app, true) {
                    continue;
                }
                // The page must wait for playback before animating the mouth, even for a silent remark.
                reply["voiced"] = json!(true);
                integration::broadcast(&app, "receiveReply", &reply, false);
                integration::notify(&app);
                let text = reply["text"].as_str().unwrap_or("");
                let language = reply["language"].as_str().unwrap_or("auto");
                speak_proactive(&app, text, language).await;
            }
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;
    #[test]
    fn cloud_observation_requires_both_opt_ins() {
        let cache = json!({"foreground":{"title":"private"},"media":{"title":"song"},"screen":{"text":"private"},"platform":{"foreground":"private"},"weather":{"latitude":22.3,"longitude":114.1,"temperature":24}});
        let denied = context(
            &json!({"aiProvider":"cloud","awarenessEnabled":true,"mediaAwarenessEnabled":true,"screenAwarenessEnabled":true}),
            &cache,
        );
        assert!(
            denied["foreground"].is_null()
                && denied["screen"].is_null()
                && denied["media"].is_null()
        );
        assert!(denied.get("platform").is_none());
        assert!(denied["weather"].get("latitude").is_none());
        let allowed = context(
            &json!({"aiProvider":"cloud","cloudSharesAwareness":true,"awarenessEnabled":true,"mediaAwarenessEnabled":true,"screenAwarenessEnabled":true}),
            &cache,
        );
        assert_eq!(allowed["foreground"]["title"], "private");
        let off = context(
            &json!({"awarenessEnabled":false,"awarenessActivity":true}),
            &cache,
        );
        assert!(off["foreground"].is_null());
    }
    #[test]
    fn interruption_guards_cover_quiet_nights_calls_and_lock() {
        let s = json!({"quietStart":"23:00","quietEnd":"07:00"});
        let day = NaiveTime::from_hms_opt(12, 0, 0).unwrap();
        assert!(!inhibited(&s, &json!({}), false, false, day));
        for key in ["quiet", "locked", "fullscreen", "sleeping"] {
            assert!(inhibited(&s, &json!({key:true}), false, false, day));
        }
        assert!(inhibited(&s, &json!({}), false, true, day));
        assert!(inhibited(&s, &json!({}), true, false, day));
        assert!(inhibited(
            &s,
            &json!({}),
            false,
            false,
            NaiveTime::from_hms_opt(1, 0, 0).unwrap()
        ));
        assert!(!quiet_hours(
            &json!({"quietStart":"01:00","quietEnd":"01:00"}),
            day
        ));
    }
    #[test]
    fn media_state_matches_smtc_envelope() {
        assert_eq!(
            music_status(&json!({"session":{"title":"Song","artist":"Artist","status":"Playing"}}))
                ["playing"],
            true
        );
        assert_eq!(
            music_status(&json!({"session":{"title":"Song","status":"Paused"}}))["playing"],
            false
        );
        assert_eq!(music_status(&Value::Null)["title"], "");
    }
    #[test]
    fn diary_uses_five_am_day_boundary_and_skips_existing() {
        let now = Local
            .with_ymd_and_hms(2026, 11, 10, 2, 0, 0)
            .single()
            .unwrap();
        assert_eq!(diary_days(now, false, &json!([])), vec!["2026-11-08"]);
        assert_eq!(
            diary_days(now, true, &json!([{ "day":"2026-11-08"}])),
            vec!["2026-11-09"]
        );
    }
}
