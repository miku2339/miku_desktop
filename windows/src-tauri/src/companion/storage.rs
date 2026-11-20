use std::fs;
use std::path::{Path, PathBuf};

use chrono::{DateTime, Local};
use serde_json::{json, Value};
use uuid::Uuid;

use super::ai;

pub fn now() -> String {
    Local::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
}
pub fn id() -> String {
    Uuid::new_v4().to_string().to_uppercase()
}
pub fn day() -> String {
    Local::now().format("%Y-%m-%d").to_string()
}
pub fn diary_day() -> String {
    (Local::now() - chrono::Duration::hours(5))
        .format("%Y-%m-%d")
        .to_string()
}
pub fn short(value: &str, limit: usize) -> String {
    value.trim().chars().take(limit).collect()
}

pub fn defaults() -> Value {
    json!({"endpoint":"http://127.0.0.1:11434/v1","model":"","aiProvider":"local","cloudEndpoint":"","cloudModel":"","cloudSharesAwareness":false,"personalityPreset":"lively","customPersonality":"","nickname":"","replyLanguage":"auto","interfaceLanguage":"auto","memoryEnabled":true,"launchAtLogin":false,"speechEnabled":false,"readChatOnly":true,"speechProvider":"system","speechVoice":"","ttsProvider":"local","ttsEndpoint":"","ttsModel":"","ttsVoice":"","speechRecognitionLanguage":"auto","speechQuietEnabled":true,"quietStart":"01:00","quietEnd":"07:00","sleepEnabled":true,"proactiveEnabled":true,"vocadb.lookupEnabled":false,"songPreferenceMemory":false,"awarenessEnabled":false,"mediaAwarenessEnabled":false,"screenAwarenessEnabled":false,"latitude":null,"longitude":null,"fullMotion":false,"sceneRotationSeconds":300,"ambientEnabled":true,"selectedScene":"auto"})
}

pub fn empty_memory() -> Value {
    json!({"version":1,"firstMet":null,"lastChat":null,"messages":[],"summarizedCount":0,"summary":"","facts":[],"touchDays":[],"relationship":{"friendship":30.0,"status":"friends","offendedSince":null,"boundaryStrikes":0,"lastBoundary":null,"lastBoundaryPart":null,"lastBoundaryPenalty":null,"dailyGain":{}},"diary":[],"deletedDiaryDays":[]})
}

pub fn merge(base: &mut Value, patch: &Value) {
    if let (Some(target), Some(patch)) = (base.as_object_mut(), patch.as_object()) {
        for (key, value) in patch {
            if target.get(key).is_some_and(Value::is_object) && value.is_object() {
                merge(target.get_mut(key).unwrap(), value);
            } else {
                target.insert(key.clone(), value.clone());
            }
        }
    }
}

pub fn atomic_write(path: &Path, value: &Value) -> Result<(), String> {
    let parent = path
        .parent()
        .ok_or("The data path has no parent directory.")?;
    fs::create_dir_all(parent).map_err(|_| "The application data folder could not be created.")?;
    let temporary = parent.join(format!(".{}.tmp", Uuid::new_v4()));
    let bytes = serde_json::to_vec_pretty(value)
        .map_err(|_| "The application data could not be encoded.")?;
    let result = fs::write(&temporary, bytes).and_then(|_| fs::rename(&temporary, path));
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result.map_err(|_| "The application data could not be saved.".into())
}

fn read(path: &Path, fallback: Value, errors: &mut Vec<String>) -> Value {
    if !path.exists() {
        return fallback;
    }
    let value = fs::metadata(path)
        .ok()
        .filter(|m| m.len() <= 64 * 1_048_576)
        .and_then(|_| fs::read(path).ok())
        .and_then(|data| serde_json::from_slice::<Value>(&data).ok());
    match value {
        Some(value)
            if value.is_object() == fallback.is_object()
                && value.is_array() == fallback.is_array() =>
        {
            value
        }
        _ => {
            errors.push(format!(
                "{} could not be loaded; the original file has been preserved.",
                path.file_name().unwrap_or_default().to_string_lossy()
            ));
            fallback
        }
    }
}

#[derive(Clone)]
pub struct State {
    pub directory: PathBuf,
    pub settings: Value,
    pub memory: Value,
    pub profile: Value,
    pub notes: Vec<Value>,
    pub album: Vec<Value>,
    pub songs: Vec<Value>,
    pub favorites: Vec<String>,
    pub calendar: Value,
    pub games: Value,
    pub ephemeral_messages: Vec<Value>,
    pub just_forgiven: bool,
    pub forgave_accident: bool,
    pub wake_until: Option<i64>,
    pub last_proactive: Option<i64>,
    pub revision: u64,
    pub catalog_revision: u128,
    pub voice_turn: Option<Value>,
    pub errors: Vec<String>,
}

impl State {
    pub fn load(directory: PathBuf) -> Self {
        let mut errors = Vec::new();
        let mut settings = defaults();
        merge(
            &mut settings,
            &read(
                &directory.join("companion-settings.json"),
                json!({}),
                &mut errors,
            ),
        );
        let mut memory = empty_memory();
        merge(
            &mut memory,
            &read(&directory.join("memory.json"), empty_memory(), &mut errors),
        );
        for key in [
            "messages",
            "facts",
            "touchDays",
            "diary",
            "deletedDiaryDays",
        ] {
            if !memory[key].is_array() {
                memory[key] = json!([]);
            }
        }
        if !memory["relationship"].is_object() {
            memory["relationship"] = empty_memory()["relationship"].clone();
        }
        let profile = read(
            &directory.join("profile.json"),
            json!({"name":"","birthday":"","likes":"","dislikes":""}),
            &mut errors,
        );
        let notes = read(&directory.join("notes.json"), json!([]), &mut errors)
            .as_array()
            .cloned()
            .unwrap_or_default();
        let album = read(
            &directory.join("album/album.json"),
            json!({"version":1,"entries":[]}),
            &mut errors,
        )["entries"]
            .as_array()
            .cloned()
            .unwrap_or_default();
        let songs = read(
            &directory.join("Knowledge/miku-knowledge-custom.json"),
            json!({"schemaVersion":1,"version":"custom","entries":[]}),
            &mut errors,
        )["entries"]
            .as_array()
            .cloned()
            .unwrap_or_default();
        let favorites = read(
            &directory.join("Knowledge/song-preferences.json"),
            json!([]),
            &mut errors,
        )
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .map(str::to_string)
        .collect();
        let calendar = read(
            &directory.join("events.json"),
            json!({"checked":null,"events":[],"lastResult":{}}),
            &mut errors,
        );
        Self {
            directory,
            settings,
            memory,
            profile,
            notes,
            album,
            songs,
            favorites,
            calendar,
            games: json!({}),
            ephemeral_messages: vec![],
            just_forgiven: false,
            forgave_accident: false,
            wake_until: None,
            last_proactive: Some(Local::now().timestamp()),
            revision: 0,
            catalog_revision: Uuid::new_v4().as_u128(),
            voice_turn: None,
            errors,
        }
    }

    pub fn persist(&self) -> Result<(), String> {
        if !self.errors.is_empty() {
            return Err(self.errors.join(" "));
        }
        for (path, value) in [
            ("companion-settings.json", self.settings.clone()),
            ("memory.json", self.memory.clone()),
            ("profile.json", self.profile.clone()),
            ("notes.json", json!(self.notes)),
            (
                "album/album.json",
                json!({"version":1,"entries":self.album}),
            ),
            (
                "Knowledge/miku-knowledge-custom.json",
                json!({"schemaVersion":1,"version":"custom","entries":self.songs}),
            ),
            ("Knowledge/song-preferences.json", json!(self.favorites)),
        ] {
            atomic_write(&self.directory.join(path), &value)?;
        }
        Ok(())
    }

    pub fn clean_unused_chat_images(&self) {
        let backup = fs::read(self.directory.join("memory-before-reset.json"))
            .ok()
            .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
            .unwrap_or(Value::Null);
        let used: std::collections::HashSet<_> = self.memory["messages"]
            .as_array()
            .into_iter()
            .flatten()
            .chain(self.ephemeral_messages.iter())
            .chain(backup["messages"].as_array().into_iter().flatten())
            .filter_map(|m| m["imageName"].as_str())
            .collect();
        if let Ok(files) = fs::read_dir(self.directory.join("images")) {
            for file in files.flatten() {
                let name = file.file_name().to_string_lossy().into_owned();
                if ai::matches(r"^[0-9a-fA-F-]{36}\.(?:jpg|png)$", &name)
                    && !used.contains(name.as_str())
                    && !file.path().is_symlink()
                {
                    let _ = fs::remove_file(file.path());
                }
            }
        }
    }

    pub fn relationship(&self) -> Value {
        let r = &self.memory["relationship"];
        let friendship =
            (r["friendship"].as_f64().unwrap_or(30.0).clamp(0.0, 100.0) * 10.0).round() / 10.0;
        let counts = self.memory["touchDays"]
            .as_array()
            .into_iter()
            .flatten()
            .find(|d| d["day"] == day())
            .map(|d| d["counts"].clone())
            .unwrap_or(json!({}));
        let days_known = self.memory["firstMet"]
            .as_str()
            .and_then(|s| DateTime::parse_from_rfc3339(s).ok())
            .map(|first| {
                Local::now()
                    .date_naive()
                    .signed_duration_since(first.with_timezone(&Local).date_naive())
                    .num_days()
                    .max(0)
            })
            .unwrap_or(0);
        let hours_since_chat = self.memory["lastChat"]
            .as_str()
            .and_then(|s| DateTime::parse_from_rfc3339(s).ok())
            .map(|last| {
                Local::now()
                    .signed_duration_since(last)
                    .num_seconds()
                    .max(0) as f64
                    / 3600.0
            });
        json!({"friendship":friendship,"level":level(friendship),"status":r["status"].as_str().unwrap_or("friends"),"offended":!r["offendedSince"].is_null(),"justForgiven":self.just_forgiven,"forgaveAccident":self.forgave_accident,"strikesToday":counts["boundary"].as_u64().unwrap_or(0),"today":counts,"daysKnown":days_known,"hoursSinceLastChat":hours_since_chat})
    }

    pub fn add_message(&mut self, role: &str, text: &str, image_name: Option<String>) -> Value {
        let message =
            json!({"id":id(),"role":role,"text":text,"date":now(),"imageName":image_name});
        if self.settings["memoryEnabled"] != false {
            let messages = self.memory["messages"].as_array_mut().unwrap();
            messages.push(message.clone());
            let drop = messages.len().saturating_sub(240);
            if drop > 0 {
                messages.drain(..drop);
            }
            let summarized = self.memory["summarizedCount"].as_u64().unwrap_or(0) as usize;
            self.memory["summarizedCount"] = json!(summarized.saturating_sub(drop));
        } else {
            self.ephemeral_messages.push(message.clone());
            if self.ephemeral_messages.len() > 240 {
                self.ephemeral_messages
                    .drain(..self.ephemeral_messages.len() - 240);
            }
            self.trim_ephemeral_images();
        }
        if self.memory["firstMet"].is_null() {
            self.memory["firstMet"] = json!(now());
        }
        self.memory["lastChat"] = json!(now());
        message
    }

    pub fn add_ephemeral_image(&mut self, image: Option<String>) {
        if let Some(message) = self.ephemeral_messages.last_mut() {
            if let Some(image) = image {
                message["image"] = json!(image);
            }
        }
        self.trim_ephemeral_images();
    }

    fn trim_ephemeral_images(&mut self) {
        let mut bytes = 0usize;
        for (index, message) in self.ephemeral_messages.iter_mut().rev().enumerate() {
            if let Some(image) = message["image"].as_str() {
                bytes = bytes.saturating_add(image.len());
                if index >= 12 || bytes > 20 * 1_048_576 {
                    message.as_object_mut().unwrap().remove("image");
                }
            }
        }
    }

    pub fn gain(&mut self, amount: f64, kind: &str, cap: f64) {
        let key = format!("{}-{kind}", day());
        let r = &mut self.memory["relationship"];
        let gained = r["dailyGain"][&key].as_f64().unwrap_or(0.0);
        let allowed = amount.min((cap - gained).max(0.0));
        r["dailyGain"][&key] = json!(gained + allowed);
        r["friendship"] =
            json!((r["friendship"].as_f64().unwrap_or(30.0) + allowed).clamp(0.0, 100.0));
        if let Some(gains) = r["dailyGain"].as_object_mut() {
            let cutoff = (Local::now() - chrono::Duration::days(4))
                .format("%Y-%m-%d")
                .to_string();
            gains.retain(|k, _| k.as_str() >= cutoff.as_str());
        }
    }

    fn touch_count(&mut self, kind: &str) {
        let today = day();
        let days = self.memory["touchDays"].as_array_mut().unwrap();
        let index = days
            .iter()
            .position(|d| d["day"] == today)
            .unwrap_or_else(|| {
                days.push(json!({"day":today,"counts":{}}));
                days.len() - 1
            });
        let count = days[index]["counts"][kind].as_u64().unwrap_or(0);
        days[index]["counts"][kind] = json!(count + 1);
        if days.len() > 14 {
            days.drain(..days.len() - 14);
        }
        if self.memory["firstMet"].is_null() {
            self.memory["firstMet"] = json!(now());
        }
    }

    pub fn record_touch(&mut self, kind: &str, part: Option<&str>) {
        let friendship = self.memory["relationship"]["friendship"]
            .as_f64()
            .unwrap_or(30.0);
        let delta = match kind {
            "headPat" | "headStroke" => 0.4,
            "handHold" => 0.5,
            "wave" | "hello" => 0.2,
            "poke" => 0.1,
            "carry" => [-0.3, 0.0, 0.3, 0.4][level(friendship) as usize],
            "dizzy" => -1.5,
            "sulk" => -3.0,
            "ouch" => -0.5,
            "game" => 0.5,
            "boundary" => 0.0,
            _ => return,
        };
        self.touch_count(kind);
        let offended = !self.memory["relationship"]["offendedSince"].is_null();
        if kind == "boundary" {
            let penalty = if offended { 12.0 } else { 8.0 };
            let r = &mut self.memory["relationship"];
            r["friendship"] = json!((friendship - penalty).max(0.0));
            r["lastBoundaryPenalty"] = json!(penalty);
            if !offended {
                r["offendedSince"] = json!(now());
            }
            r["boundaryStrikes"] = json!(r["boundaryStrikes"].as_u64().unwrap_or(0) + 1);
            r["lastBoundary"] = json!(now());
            r["lastBoundaryPart"] = json!(part
                .filter(|v| ["chest", "skirt"].contains(v))
                .unwrap_or("chest"));
            self.just_forgiven = false;
        } else if delta < 0.0 {
            self.memory["relationship"]["friendship"] = json!((friendship + delta).max(0.0));
        } else if !offended {
            self.gain(
                delta,
                if kind == "game" { "game" } else { "touch" },
                if kind == "game" { 2.0 } else { 5.0 },
            );
        }
    }

    pub fn note_user(&mut self, text: &str, intent: Option<&str>) -> Option<String> {
        self.just_forgiven = false;
        self.forgave_accident = false;
        let lower = text.to_lowercase();
        let accident = !ai::matches(
            r"(?:不是|並非|并非|唔係)(?:不小心|誤觸|误触|手滑|意外)|(?:not|wasn't|isn't)\s+(?:an?\s+)?accident|わざと(?:です|だ|やった)|일부러\s*(?:했|그랬)",
            &lower,
        ) && [
            "唔小心",
            "不小心",
            "唔係有心",
            "不是有心",
            "唔係故意",
            "不是故意",
            "唔係特登",
            "非故意",
            "意外",
            "手滑",
            "撳錯",
            "按錯",
            "點錯",
            "誤觸",
            "accident",
            "didn't mean",
            "did not mean",
            "didnt mean",
            "by mistake",
            "misclick",
            "slipped",
            "わざとじゃ",
            "わざとではない",
            "うっかり",
            "間違えて",
            "事故",
            "실수였어",
            "실수했어",
            "잘못 눌렀",
            "잘못눌렀",
            "일부러 그런 게 아니",
            "일부러 한 게 아니",
        ]
        .iter()
        .any(|w| lower.contains(w));
        let apology = !ai::matches(
            r"(?:미안|죄송)(?:하지\s*않|한\s*(?:게|것이)\s*아니)|사과(?:하지\s*않|할\s*생각\s*없)|안\s*(?:미안|죄송)",
            &lower,
        ) && [
            "對不起",
            "对不起",
            "對唔住",
            "对唔住",
            "唔好意思",
            "不好意思",
            "抱歉",
            "道歉",
            "我錯",
            "我错",
            "sorry",
            "apologi",
            "my bad",
            "forgive me",
            "ごめん",
            "すみません",
            "すいません",
            "申し訳",
            "許して",
            "미안",
            "죄송",
            "사과할게",
            "사과해",
            "용서해",
            "잘못했어",
        ]
        .iter()
        .any(|w| lower.contains(w));
        if !self.memory["relationship"]["offendedSince"].is_null() && (accident || apology) {
            let r = &mut self.memory["relationship"];
            let regained = if accident {
                r["lastBoundaryPenalty"].as_f64().unwrap_or(8.0)
            } else {
                2.0
            };
            r["friendship"] =
                json!((r["friendship"].as_f64().unwrap_or(30.0) + regained).min(100.0));
            r["offendedSince"] = Value::Null;
            if accident {
                r["boundaryStrikes"] =
                    json!(r["boundaryStrikes"].as_u64().unwrap_or(0).saturating_sub(1));
                let boundary_day = r["lastBoundary"]
                    .as_str()
                    .and_then(|s| DateTime::parse_from_rfc3339(s).ok())
                    .map(|d| d.with_timezone(&Local).format("%Y-%m-%d").to_string());
                r["lastBoundary"] = Value::Null;
                r["lastBoundaryPenalty"] = Value::Null;
                if let Some(days) = self.memory["touchDays"].as_array_mut() {
                    if let Some(entry) = days
                        .iter_mut()
                        .find(|d| Some(d["day"].as_str().unwrap_or("").to_string()) == boundary_day)
                    {
                        let remaining = entry["counts"]["boundary"]
                            .as_u64()
                            .unwrap_or(0)
                            .saturating_sub(1);
                        if remaining == 0 {
                            entry["counts"]
                                .as_object_mut()
                                .map(|o| o.remove("boundary"));
                        } else {
                            entry["counts"]["boundary"] = json!(remaining);
                        }
                    }
                }
            }
            self.just_forgiven = true;
            self.forgave_accident = accident;
        }
        let confession = intent
            .map(|i| i == "confession")
            .unwrap_or_else(|| direct_confession(text));
        if !confession {
            return None;
        }
        let r = &self.memory["relationship"];
        Some(
            if !r["offendedSince"].is_null() {
                "upset"
            } else if r["status"] == "dating" {
                "alreadyDating"
            } else if self.just_forgiven {
                "recovering"
            } else if r["friendship"].as_f64().unwrap_or(30.0) < 75.0 {
                "notReady"
            } else {
                "accepted"
            }
            .into(),
        )
    }
}

pub fn level(friendship: f64) -> u8 {
    if friendship >= 75.0 {
        3
    } else if friendship >= 50.0 {
        2
    } else if friendship >= 25.0 {
        1
    } else {
        0
    }
}

pub fn direct_confession(text: &str) -> bool {
    static PATTERNS: std::sync::OnceLock<Vec<regex::Regex>> = std::sync::OnceLock::new();
    let patterns = PATTERNS.get_or_init(|| {
        let patterns: Vec<String> = serde_json::from_str(include_str!("confession-patterns.json"))
            .expect("Mac confession patterns");
        patterns
            .into_iter()
            .map(|pattern| regex::Regex::new(&pattern).expect("Mac confession regular expression"))
            .collect()
    });
    let normalized = text.trim().to_lowercase();
    let clauses: Vec<_> = normalized
        .split(['。', '.', '！', '!', '？', '?', '\n'])
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .collect();
    !clauses.is_empty()
        && clauses
            .iter()
            .all(|clause| patterns.iter().any(|pattern| pattern.is_match(clause)))
}

pub fn clean_fact(raw: &str) -> Option<String> {
    let text = raw
        .trim()
        .trim_matches(['-', '•', '*', '·', '"', '“', '”', '「', '」'])
        .trim();
    if !(3..=120).contains(&text.chars().count()) {
        return None;
    }
    let lower = text.to_lowercase();
    if [
        "password",
        "passcode",
        "密碼",
        "密码",
        "パスワード",
        "credit card",
        "信用卡",
        "api key",
        "token",
        "비밀번호",
        "암호",
        "신용카드",
        "주민등록",
        "계좌번호",
        "건강",
        "진단",
        "복용",
        "토큰",
    ]
    .iter()
    .any(|w| lower.contains(w))
        || ai::matches(r"[0-9][0-9 -]{7,}[0-9]", text)
    {
        return None;
    }
    Some(text.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn state() -> State {
        State::load(std::env::temp_dir().join(format!("miku-memory-test-{}", Uuid::new_v4())))
    }
    #[test]
    fn apology_and_accident_have_different_rollback_semantics() {
        let mut s = state();
        s.record_touch("boundary", Some("skirt"));
        assert_eq!(s.relationship()["friendship"], 22.0);
        s.note_user("我剛剛不小心點錯", None);
        assert_eq!(s.relationship()["friendship"], 30.0);
        assert_eq!(s.relationship()["strikesToday"], 0);
        assert_eq!(s.relationship()["status"], "friends");
    }
    #[test]
    fn ordinary_affection_cannot_upgrade_relationship() {
        assert!(!direct_confession("可以抱抱嗎？"));
        assert!(!direct_confession("朋友說我愛你是什麼意思？"));
        assert!(direct_confession("Will you be my girlfriend?"));
        let mut s = state();
        assert_eq!(s.note_user("I love you", None).as_deref(), Some("notReady"));
    }
    #[test]
    fn touch_gain_is_capped_and_hover_is_not_a_touch() {
        let mut s = state();
        for _ in 0..100 {
            s.record_touch("headPat", None);
        }
        assert_eq!(s.relationship()["friendship"], 35.0);
        let before = s.memory.clone();
        s.record_touch("hover", None);
        assert_eq!(before, s.memory);
    }
    #[test]
    fn secret_facts_are_not_remembered() {
        assert!(clean_fact("My password is example").is_none());
        assert!(clean_fact("用戶的電話是123456789").is_none());
        assert!(clean_fact("用戶喜歡初音未來。").is_some());
    }

    #[test]
    fn disabled_memory_keeps_recent_images_in_ram_only() {
        let mut s = state();
        s.settings["memoryEnabled"] = json!(false);
        s.add_message("user", "picture", None);
        s.add_ephemeral_image(Some("data:image/png;base64,example".into()));
        assert!(s.ephemeral_messages[0]["image"].is_string());
        assert!(s.memory["messages"].as_array().unwrap().is_empty());
        for _ in 0..12 {
            s.add_message("assistant", "reply", None);
        }
        assert!(s.ephemeral_messages[0]["image"].is_null());
        assert!(!s.directory.exists());
    }
}
