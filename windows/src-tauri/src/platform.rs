//! Windows services. Run `action` on a blocking worker; speech playback returns a job immediately.

#[cfg(windows)]
mod audio;
mod credentials;
mod helper;
#[cfg(windows)]
mod monitor;
mod native;

pub use credentials::{delete_secret, load_secret, store_secret};
pub use helper::current_speech_job;
pub use native::{claim_instance, release_instance};

use serde_json::{json, Value};
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

static STOPPING: AtomicBool = AtomicBool::new(false);

fn inventory() -> &'static Mutex<Value> {
    static INVENTORY: OnceLock<Mutex<Value>> = OnceLock::new();
    INVENTORY.get_or_init(|| Mutex::new(json!({"voices":[],"recognizers":[],"checked":false})))
}

fn paused_media() -> &'static Mutex<Option<(String, Value)>> {
    static PAUSED: OnceLock<Mutex<Option<(String, Value)>>> = OnceLock::new();
    PAUSED.get_or_init(|| Mutex::new(None))
}

pub fn shutdown() {
    helper::stop_listening();
    let _ = helper::stop_speech();
}

pub fn resume_paused_on_exit(data_dir: &Path) -> Result<Value, String> {
    STOPPING.store(true, Ordering::SeqCst);
    let mut paused = paused_media()
        .lock()
        .map_err(|_| "Media resume state is unavailable")?;
    let Some((_, identity)) = paused.take() else {
        return Ok(json!({"resumed":false,"reason":"no-paused-session"}));
    };
    helper::run(
        "media_resume",
        json!({"userInitiated":true,"resume":identity}),
        data_dir,
        Duration::from_secs(25),
    )
}

pub fn snapshot() -> Value {
    let speech = inventory()
        .lock()
        .map(|value| value.clone())
        .unwrap_or(Value::Null);
    let mut status = native::system_snapshot(false);
    status["capabilities"] = json!({
        "credentialManager":cfg!(windows),"awareness":cfg!(windows),"media":cfg!(windows),"weather":cfg!(windows),
        "screenCapture":cfg!(windows),"autostart":cfg!(windows),"tdaImport":cfg!(windows),"updateCheck":cfg!(windows),
        "nativeSpeech":cfg!(windows),"automaticLanguageDetection":false,"automaticBargeIn":false,"speechInventoryChecked":speech["checked"],"voices":speech["voices"],"recognizers":speech["recognizers"],
        "microphoneActivity":cfg!(windows),"exactMicrophoneActivity":false,"microphoneActivityScope":"wasapi-capture-sessions",
        "ttsAvailable":speech["ttsAvailable"],"sttAvailable":speech["sttAvailable"],"exactDoNotDisturb":false,"displaySleepEvents":status["displayMonitor"]["available"]
    });
    status["speech"] = helper::speech_status()
        .unwrap_or_else(|error| json!({"state":"unavailable","error":error}));
    status
}

fn field<'a>(payload: &'a Value, key: &str) -> Result<&'a str, String> {
    payload
        .get(key)
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| format!("Missing {key}"))
}

fn web_url(value: &str) -> Result<tauri::Url, String> {
    if value.len() > 8192 || value.chars().any(|c| c.is_control() || c == '\\') {
        return Err("Invalid web URL".into());
    }
    let url = tauri::Url::parse(value).map_err(|_| "Invalid web URL")?;
    if !matches!(url.scheme(), "http" | "https")
        || url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
    {
        return Err("Only HTTP and HTTPS web URLs without embedded credentials are allowed".into());
    }
    Ok(url)
}

fn language(payload: &Value) -> Result<String, String> {
    let value = payload
        .get("language")
        .and_then(Value::as_str)
        .unwrap_or("auto");
    let language = match value {
        "auto" => "",
        "zh" | "mandarin" | "zh-Hant" => "zh-TW",
        "cantonese" | "yue" => "zh-HK",
        "ja" | "japanese" => "ja-JP",
        "ko" | "korean" => "ko-KR",
        "en" | "english" => "en-US",
        other => other,
    };
    if language.len() > 35
        || !language
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-')
    {
        return Err("Invalid speech language".into());
    }
    Ok(language.to_string())
}

/// Actions may show a user-requested picker or use the network. Microphone and screen input require explicit opt-in.
pub fn action(name: &str, mut payload: Value, data_dir: &Path) -> Result<Value, String> {
    if name == "snapshot" || name == "capabilities" {
        return Ok(snapshot());
    }
    if !cfg!(windows) {
        return Err("Windows platform services are unavailable on this platform".into());
    }
    if !payload.is_object() {
        payload = json!({});
    }
    match name {
        "single_instance" => {
            claim_instance()?;
            Ok(json!({"claimed":true}))
        }
        "speak_status" | "speech_status" => {
            let status = helper::speech_status()?;
            if let Some(requested) = payload.get("jobId").and_then(Value::as_u64) {
                if status.get("jobId").and_then(Value::as_u64) != Some(requested) {
                    return Ok(
                        json!({"jobId":requested,"state":"stopped","running":false,"event":"voice-end"}),
                    );
                }
            }
            Ok(status)
        }
        "speech_stop" | "stop_speech" => {
            helper::stop_speech_job(payload.get("jobId").and_then(Value::as_u64))
        }
        "listen_stop" => Ok(helper::stop_listening()),
        "speak" => {
            let text = field(&payload, "text")?;
            if text.chars().count() > 20000 {
                return Err("Speech text is too long".into());
            }
            if payload
                .get("voice")
                .and_then(Value::as_str)
                .is_some_and(|voice| voice.len() > 512)
            {
                return Err("Invalid voice identifier".into());
            }
            payload["language"] = Value::String(language(&payload)?);
            payload["rate"] = Value::from(
                payload
                    .get("rate")
                    .and_then(Value::as_i64)
                    .unwrap_or(0)
                    .clamp(-10, 10),
            );
            helper::speak("speak", payload, data_dir)
        }
        "play_audio" => {
            let path = Path::new(field(&payload, "path")?)
                .canonicalize()
                .map_err(|_| "Audio file does not exist")?;
            if !path.is_file()
                || !path
                    .extension()
                    .and_then(std::ffi::OsStr::to_str)
                    .is_some_and(|ext| ext.eq_ignore_ascii_case("wav"))
            {
                return Err("Native audio playback requires a WAV file".into());
            }
            if std::fs::metadata(&path)
                .map_err(|_| "Audio file is unavailable")?
                .len()
                > 64 * 1024 * 1024
            {
                return Err("Audio file exceeds its size limit".into());
            }
            payload["path"] = Value::String(path.to_string_lossy().into_owned());
            helper::speak("play_audio", payload, data_dir)
        }
        "listen_once" => {
            if payload.get("userInitiated") != Some(&Value::Bool(true)) {
                return Err("Start speech input with the microphone button first".into());
            }
            if native::system_snapshot(false)["sessionLocked"] == true {
                return Err("Unlock the Windows session before using the microphone".into());
            }
            payload["language"] = Value::String(language(&payload)?);
            let seconds = payload
                .get("seconds")
                .and_then(Value::as_u64)
                .unwrap_or(12)
                .clamp(1, 30);
            payload["seconds"] = Value::from(seconds);
            helper::run(name, payload, data_dir, Duration::from_secs(seconds + 10))
        }
        "voices" => {
            let mut result = helper::run(name, payload, data_dir, Duration::from_secs(20))?;
            result["checked"] = Value::Bool(true);
            if let Ok(mut cached) = inventory().lock() {
                *cached = result.clone();
            }
            Ok(result)
        }
        "awareness" => {
            let activity = payload
                .get("activityEnabled")
                .and_then(Value::as_bool)
                .unwrap_or(false);
            let media = payload
                .get("mediaEnabled")
                .and_then(Value::as_bool)
                .unwrap_or(false);
            let mut result = native::system_snapshot(activity);
            if media {
                match helper::run("media", json!({}), data_dir, Duration::from_secs(25)) {
                    Ok(value) => result["media"] = value,
                    Err(error) => result["media"] = json!({"available":false,"error":error}),
                }
            } else {
                result["media"] = Value::Null;
            }
            Ok(result)
        }
        "media" => {
            if payload.get("mediaEnabled") != Some(&Value::Bool(true)) {
                return Err(
                    "Enable media awareness before reading the current media session".into(),
                );
            }
            helper::run(name, payload, data_dir, Duration::from_secs(25))
        }
        "media_pause" | "media_resume" => {
            if payload["userInitiated"] != true {
                return Err("Media control requires an explicit user call action".into());
            }
            let mut paused = paused_media()
                .lock()
                .map_err(|_| "Media resume state is unavailable")?;
            if name == "media_pause" {
                if STOPPING.load(Ordering::SeqCst) {
                    return Err("The app is exiting; media pause was cancelled".into());
                }
                if let Some((token, _)) = paused.as_ref() {
                    return Ok(json!({"paused":true,"resumeToken":token,"alreadyPaused":true}));
                }
                let mut result = helper::run(
                    name,
                    json!({"userInitiated":true}),
                    data_dir,
                    Duration::from_secs(25),
                )?;
                let identity = result
                    .as_object_mut()
                    .and_then(|value| value.remove("resume"));
                if result["paused"] == true {
                    let identity = identity
                        .filter(Value::is_object)
                        .ok_or("Media pause did not return a resume identity")?;
                    let token = uuid::Uuid::new_v4().to_string();
                    *paused = Some((token.clone(), identity));
                    result["resumeToken"] = json!(token);
                } else {
                    result["resumeToken"] = Value::Null;
                }
                Ok(result)
            } else {
                let token = field(&payload, "resumeToken")?;
                if paused
                    .as_ref()
                    .map(|(saved, _)| saved != token)
                    .unwrap_or(true)
                {
                    return Ok(json!({"resumed":false,"reason":"unknown-token"}));
                }
                let (_, identity) = paused.take().unwrap();
                helper::run(
                    name,
                    json!({"userInitiated":true,"resume":identity}),
                    data_dir,
                    Duration::from_secs(25),
                )
            }
        }
        "weather" => {
            let latitude = payload
                .get("latitude")
                .and_then(Value::as_f64)
                .filter(|v| v.is_finite() && (-90.0..=90.0).contains(v))
                .ok_or("Set a valid weather latitude first")?;
            let longitude = payload
                .get("longitude")
                .and_then(Value::as_f64)
                .filter(|v| v.is_finite() && (-180.0..=180.0).contains(v))
                .ok_or("Set a valid weather longitude first")?;
            payload["latitude"] = Value::from(latitude);
            payload["longitude"] = Value::from(longitude);
            let timezone = payload
                .get("timezone")
                .and_then(Value::as_str)
                .unwrap_or("auto")
                .to_string();
            if timezone.len() > 80
                || !timezone
                    .chars()
                    .all(|c| c.is_ascii_alphanumeric() || matches!(c, '/' | '_' | '-' | '+'))
            {
                return Err("Invalid weather timezone".into());
            }
            payload["timezone"] = Value::from(timezone);
            helper::run(name, payload, data_dir, Duration::from_secs(25))
        }
        "open_url" => {
            payload["url"] = Value::from(web_url(field(&payload, "url")?)?.as_str());
            helper::run(name, payload, data_dir, Duration::from_secs(15))
        }
        "autostart" => {
            if payload
                .get("enabled")
                .is_some_and(|value| !value.is_boolean())
            {
                return Err("Autostart enabled must be a boolean".into());
            }
            let executable =
                std::env::current_exe().map_err(|_| "Could not determine the app executable")?;
            payload["executable"] = Value::String(executable.to_string_lossy().into_owned());
            helper::run(name, payload, data_dir, Duration::from_secs(15))
        }
        "update_check" => {
            payload["currentVersion"] = Value::from(env!("CARGO_PKG_VERSION"));
            helper::run(name, payload, data_dir, Duration::from_secs(25))
        }
        "import_tda" => {
            field(&payload, "path")?;
            helper::run(name, payload, data_dir, Duration::from_secs(60))
        }
        "export_file" | "export_json" => {
            let suggested = field(&payload, "suggestedName")?;
            if suggested.chars().count() > 120
                || suggested.chars().any(|c| {
                    c.is_control()
                        || matches!(c, '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|')
                })
            {
                return Err("Invalid export file name".into());
            }
            if name == "export_file" {
                let path = Path::new(field(&payload, "sourcePath")?)
                    .canonicalize()
                    .map_err(|_| "Album image is unavailable")?;
                let root = data_dir
                    .canonicalize()
                    .map_err(|_| "App data folder is unavailable")?;
                let extension = path
                    .extension()
                    .and_then(std::ffi::OsStr::to_str)
                    .unwrap_or("")
                    .to_ascii_lowercase();
                if !path.starts_with(root)
                    || !path.is_file()
                    || !["jpg", "jpeg", "png"].contains(&extension.as_str())
                {
                    return Err("Only an image from the app's album can be exported".into());
                }
                payload["sourcePath"] = Value::String(path.to_string_lossy().into_owned());
            } else {
                let document = field(&payload, "document")?;
                if document.len() > 8 * 1024 * 1024 {
                    return Err("Export document exceeds its size limit".into());
                }
                serde_json::from_str::<Value>(document)
                    .map_err(|_| "Export document is not valid JSON")?;
            }
            helper::run(name, payload, data_dir, Duration::from_secs(300))
        }
        "capture_screen" => {
            if payload.get("userInitiated") != Some(&Value::Bool(true))
                && payload.get("screenAwarenessEnabled") != Some(&Value::Bool(true))
            {
                return Err(
                    "Screen capture requires an explicit user action or enabled screen awareness"
                        .into(),
                );
            }
            let activity = native::system_snapshot(true);
            if activity["sessionLocked"] == true {
                return Err(
                    "Screen capture is unavailable while the Windows session is locked".into(),
                );
            }
            let app = activity["foreground"]["app"]
                .as_str()
                .unwrap_or("")
                .to_ascii_lowercase();
            if app.is_empty() {
                return Err(
                    "The foreground app could not be checked safely for screen capture".into(),
                );
            }
            if [
                "1password.exe",
                "bitwarden.exe",
                "credentialuibroker.exe",
                "keepass.exe",
                "keepassxc.exe",
                "logonui.exe",
                "systemsettings.exe",
                "accountscontrolhost.exe",
            ]
            .contains(&app.as_str())
            {
                return Err(
                    "Screen capture is unavailable while a password or sign-in window is active"
                        .into(),
                );
            }
            helper::run(name, payload, data_dir, Duration::from_secs(20))
        }
        "pick_tda" | "pick_file" => helper::run(name, payload, data_dir, Duration::from_secs(300)),
        "open_data" | "audio_devices" | "system_info" => {
            helper::run(name, payload, data_dir, Duration::from_secs(25))
        }
        _ => Err(format!("Unknown platform action: {name}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn web_links_cannot_start_commands_or_contain_credentials() {
        for link in [
            "file:///C:/Windows/notepad.exe",
            "javascript:alert(1)",
            "https://user:secret@example.com",
            "https://example.com\n",
            "ms-settings:privacy-microphone",
            "https:\\example.com",
        ] {
            assert!(web_url(link).is_err(), "{link}");
        }
        assert!(web_url("https://bowlroll.net/file/16344").is_ok());
        assert!(web_url("http://127.0.0.1:11434").is_ok());
    }
    #[test]
    fn speech_language_aliases_are_explicit() {
        assert_eq!(language(&json!({"language":"cantonese"})).unwrap(), "zh-HK");
        assert_eq!(language(&json!({"language":"ja"})).unwrap(), "ja-JP");
        assert_eq!(language(&json!({"language":"auto"})).unwrap(), "");
        assert!(language(&json!({"language":"en-US;Start-Process"})).is_err());
    }
}
