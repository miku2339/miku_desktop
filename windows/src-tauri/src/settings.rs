//! What the shell remembers between launches, in `%APPDATA%\MikuDesktop\settings.json`.
//! Same names as the macOS `UserDefaults` keys so data can move between platforms later.

use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Settings {
    pub interactive_mode: bool,
    pub selected_scene: String,
    /// Where she was pinned after a drag (0…1 across the screen), like macOS `pinnedAnchor`.
    pub pinned_anchor: Option<f64>,
}

impl Default for Settings {
    fn default() -> Self {
        Self { interactive_mode: true, selected_scene: "auto".into(), pinned_anchor: None }
    }
}

impl Settings {
    pub fn load(data_dir: &Path) -> Self {
        std::fs::read(data_dir.join("settings.json"))
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default()
    }

    pub fn save(&self, data_dir: &Path) {
        if std::fs::create_dir_all(data_dir).is_err() {
            return;
        }
        let path = data_dir.join("settings.json");
        let temporary = data_dir.join("settings.json.tmp");
        if let Ok(json) = serde_json::to_vec_pretty(self) {
            if std::fs::write(&temporary, json).is_ok() {
                let _ = std::fs::rename(&temporary, &path);
            }
        }
    }
}

/// `%APPDATA%\MikuDesktop\diagnostics.log`, one JSON object per line. Only plain values from
/// the page are written (as macOS `logDiagnostic`); nothing the page sends is executed.
pub struct Diagnostics {
    path: PathBuf,
}

impl Diagnostics {
    pub fn new(data_dir: &Path) -> Self {
        Self { path: data_dir.join("diagnostics.log") }
    }

    pub fn log(&self, source: &str, entry: &Map<String, Value>) {
        let mut line = Map::new();
        let seconds = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
        line.insert("time".into(), Value::from(seconds));
        line.insert("source".into(), Value::from(source));
        for (key, value) in entry {
            if matches!(value, Value::String(_) | Value::Number(_) | Value::Bool(_) | Value::Null) {
                line.insert(key.clone(), value.clone());
            }
        }
        if let Some(parent) = self.path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        if let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(&self.path) {
            let _ = writeln!(file, "{}", Value::Object(line));
        }
    }

    pub fn note(&self, source: &str, message: &str) {
        let mut entry = Map::new();
        entry.insert("message".into(), Value::from(message));
        self.log(source, &entry);
    }
}
