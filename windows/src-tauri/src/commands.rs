use crate::{
    integration::{self, Services},
    layers, lock, panels, platform, Shell,
};
use base64::{engine::general_purpose::STANDARD, Engine};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::sync::atomic::Ordering;
use tauri::{AppHandle, Manager, WebviewWindow};

fn claim_owner(
    owner: &mut Option<String>,
    calling: &std::sync::atomic::AtomicBool,
    label: &str,
    begin_call: bool,
) -> Result<(), String> {
    if calling.load(Ordering::SeqCst) && owner.as_deref() != Some(label) {
        return Err("另一個視窗正在通話".into());
    }
    *owner = Some(label.into());
    if begin_call {
        calling.store(true, Ordering::SeqCst);
    }
    Ok(())
}

fn claim_ui(state: &Services, window: &WebviewWindow, begin_call: bool) -> Result<(), String> {
    claim_owner(
        &mut lock(&state.ui_owner),
        &state.call_active,
        window.label(),
        begin_call,
    )
}

fn check_call_owner(state: &Services, window: &WebviewWindow) -> Result<(), String> {
    let owner = lock(&state.ui_owner);
    if state.call_active.load(Ordering::SeqCst) && owner.as_deref() != Some(window.label()) {
        Err("另一個視窗正在通話".into())
    } else {
        Ok(())
    }
}

async fn native(app: &AppHandle, action: &str, payload: Value) -> Result<Value, String> {
    let path = app.state::<Shell>().data_dir.clone();
    let action = action.to_owned();
    tauri::async_runtime::spawn_blocking(move || platform::action(&action, payload, &path))
        .await
        .map_err(|_| "原生服務已中止".to_string())?
}

pub fn resume_after_call(app: &AppHandle) {
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(std::time::Duration::from_millis(500)).await;
        let services = app.state::<Services>();
        let _guard = services.call_media_gate.lock().await;
        if services.call_active.load(Ordering::SeqCst) {
            return;
        }
        let token = std::mem::replace(&mut *lock(&services.media_token), Value::Null);
        if !token.is_null() {
            let _ = native(
                &app,
                "media_resume",
                json!({"userInitiated":true,"resumeToken":token}),
            )
            .await;
        }
    });
}

#[tauri::command]
pub fn desktop_snapshot(
    window: WebviewWindow,
    app: AppHandle,
    include_songs: Option<bool>,
) -> Result<Value, String> {
    panels::trusted(&window)?;
    Ok(integration::snapshot_for(
        &app,
        include_songs.unwrap_or(false),
    ))
}

#[tauri::command]
pub async fn desktop_open(
    window: WebviewWindow,
    app: AppHandle,
    view: String,
) -> Result<(), String> {
    panels::trusted(&window)?;
    panels::open(&app, &view)
}

#[tauri::command]
pub async fn desktop_update_settings(
    window: WebviewWindow,
    app: AppHandle,
    patch: Value,
) -> Result<Value, String> {
    panels::trusted(&window)?;
    let shell = app.state::<Shell>();
    let mut core = patch.clone();
    if let Some(object) = core.as_object_mut() {
        for key in ["interactiveMode", "pinnedAnchor"] {
            object.remove(key);
        }
    }
    app.state::<Services>().companion.validate_settings(&core)?;
    let startup = patch.get("launchAtLogin").and_then(Value::as_bool);
    let previous_startup = if startup.is_some() {
        native(&app, "autostart", json!({})).await?["enabled"].as_bool()
    } else {
        None
    };
    if let Some(enabled) = startup {
        native(&app, "autostart", json!({"enabled":enabled})).await?;
    }
    if let Err(error) = app.state::<Services>().companion.update_settings(core) {
        if let Some(enabled) = previous_startup {
            if native(&app, "autostart", json!({"enabled":enabled}))
                .await
                .is_err()
            {
                return Err(format!("{error}；開機啟動設定未能回復，請重新檢查。"));
            }
        }
        return Err(error);
    }
    {
        let mut settings = lock(&shell.settings);
        if let Some(value) = patch.get("selectedScene").and_then(Value::as_str) {
            if [
                "auto",
                "shibuya",
                "ikebukuro",
                "akihabara",
                "shinjuku",
                "hallway",
                "room",
                "musicroom",
            ]
            .contains(&value)
            {
                settings.selected_scene = value.into();
            }
        }
        if let Some(value) = patch.get("pinnedAnchor") {
            settings.pinned_anchor = value
                .as_f64()
                .filter(|number| number.is_finite())
                .map(|number| number.clamp(0., 1.));
        }
        settings.save(&shell.data_dir);
    }
    if let Some(value) = patch.get("interactiveMode").and_then(Value::as_bool) {
        layers::set_interactive(&app, value);
    }
    let settings = lock(&shell.settings).clone();
    integration::broadcast(&app, "setScene", &json!(settings.selected_scene), true);
    integration::broadcast(
        &app,
        "setPinnedAnchor",
        &json!(settings.pinned_anchor),
        false,
    );
    integration::configure(&app);
    integration::notify(&app);
    Ok(integration::snapshot(&app))
}

#[tauri::command]
pub async fn desktop_send_message(
    window: WebviewWindow,
    app: AppHandle,
    text: String,
    image: Option<String>,
    voice_stream: Option<bool>,
    voice_generation: Option<u64>,
) -> Result<Value, String> {
    panels::trusted(&window)?;
    if text.len() > 48000
        || image
            .as_ref()
            .is_some_and(|data| data.len() > 22 * 1024 * 1024)
    {
        return Err("訊息或圖片太大".into());
    }
    let services = app.state::<Services>();
    if services.chatting.swap(true, Ordering::SeqCst) {
        return Err("上一則訊息還在回覆中".into());
    }
    if let Err(error) = claim_ui(&services, &window, false) {
        services.chatting.store(false, Ordering::SeqCst);
        return Err(error);
    }
    let cancelled = services.cancel_chat.notified();
    tokio::pin!(cancelled);
    cancelled.as_mut().enable();
    integration::broadcast(&app, "setThinking", &json!(true), false);
    let settings = services.companion.settings();
    let mut context = crate::scheduler::context(&settings, &lock(&services.environment));
    context["isVoiceCall"] = json!(services.call_active.load(Ordering::SeqCst));
    if let Some(request) = services.companion.music_request(&text, &context) {
        context["musicResult"] = open_music(&app, &request).await;
    }
    let streaming = voice_stream == Some(true) && services.call_active.load(Ordering::SeqCst);
    let target = window.clone();
    let calling_app = app.clone();
    let on_voice = move |mut segment: Value| -> Result<(), String> {
        if !calling_app
            .state::<Services>()
            .call_active
            .load(Ordering::SeqCst)
        {
            return Err("語音通話已停止".into());
        }
        segment["voiceGeneration"] = json!(voice_generation);
        target
            .eval(&format!(
                "window.dispatchEvent(new CustomEvent('miku-voice-segment',{{detail:{segment}}}))"
            ))
            .map_err(|_| "語音通話視窗已關閉".into())
    };
    let result = tokio::select! {
        value = async {
            if streaming { services.companion.chat_stream(text.clone(), image, context, on_voice).await }
            else { services.companion.chat(text.clone(), image, context).await }
        } => value,
        _ = &mut cancelled => Err("已停止這次回覆".into()),
    };
    services.chatting.store(false, Ordering::SeqCst);
    integration::broadcast(&app, "setThinking", &json!(false), false);
    let mut reply = result?;
    if reply["game"].is_string() {
        if let Some(lines) = reply["lines"].as_array() {
            for line in lines {
                integration::broadcast(&app, "receiveReply", line, false);
            }
        }
        integration::notify(&app);
        return Ok(reply);
    }
    let settings = services.companion.settings();
    reply["voiced"] = json!(settings["speechEnabled"] == true && speech_allowed(&app, &settings));
    integration::broadcast(&app, "receiveReply", &reply, false);
    integration::push_environment(&app, &services.companion.snapshot());
    integration::notify(&app);
    let maintenance = app.clone();
    let response = reply["text"].as_str().unwrap_or("").to_owned();
    tauri::async_runtime::spawn(async move {
        let _ = maintenance
            .state::<Services>()
            .companion
            .maintain(text, response)
            .await;
    });
    Ok(reply)
}

#[tauri::command]
pub async fn desktop_action(
    window: WebviewWindow,
    app: AppHandle,
    action: String,
    payload: Option<Value>,
) -> Result<Value, String> {
    panels::trusted(&window)?;
    let payload = payload.unwrap_or_else(|| json!({}));
    let services = app.state::<Services>();
    match action.as_str() {
        "chat_cancel" | "cancel_generation" => {
            check_call_owner(&services, &window)?;
            services.cancel_chat.notify_waiters();
            return Ok(json!({"cancelled":true}));
        }
        "voice_call_started" => {
            claim_ui(&services, &window, true)?;
            let _guard = services.call_media_gate.lock().await;
            if services.call_active.load(Ordering::SeqCst) && lock(&services.media_token).is_null()
            {
                if let Ok(value) = native(&app, "media_pause", json!({"userInitiated":true})).await
                {
                    *lock(&services.media_token) = value["resumeToken"].clone();
                }
            }
            return Ok(json!({"active":services.call_active.load(Ordering::SeqCst)}));
        }
        "voice_call_ended" => {
            if lock(&services.ui_owner).as_deref() != Some(window.label()) {
                return Ok(json!({"active":false}));
            }
            services.call_active.store(false, Ordering::SeqCst);
            services.cancel_chat.notify_waiters();
            let _ = native(&app, "listen_stop", json!({})).await;
            let _ = native(&app, "speech_stop", json!({})).await;
            integration::stop_voice(&app);
            resume_after_call(&app);
            return Ok(json!({"active":false}));
        }
        "voice_call_interrupt" => {
            check_call_owner(&services, &window)?;
            services.cancel_chat.notify_waiters();
            let _ = native(&app, "listen_stop", json!({})).await;
            let _ = native(&app, "speech_stop", json!({})).await;
            integration::stop_voice(&app);
            for _ in 0..100 {
                if !services.chatting.load(Ordering::SeqCst) {
                    break;
                }
                tokio::time::sleep(std::time::Duration::from_millis(20)).await;
            }
            if services.chatting.load(Ordering::SeqCst) {
                return Err("上一則回覆仍在停止，請稍後再試".into());
            }
            let value = services.companion.action("voice_call_interrupt", payload)?;
            integration::notify(&app);
            return Ok(value);
        }
        "voice_request" => {
            claim_ui(&services, &window, false)?;
            static NEXT_AUDIO: std::sync::atomic::AtomicU64 =
                std::sync::atomic::AtomicU64::new(1 << 40);
            let mut audio = local_voice(&app, &payload).await?;
            let id = NEXT_AUDIO.fetch_add(1, Ordering::SeqCst);
            integration::register_voice_job(&app, id, payload["text"].as_str().unwrap_or(""));
            audio["jobId"] = json!(id);
            return Ok(audio);
        }
        "voice_started" => {
            if let Some(id) = payload["jobId"].as_u64() {
                integration::start_voice_job(&app, id, &payload);
            } else {
                integration::start_voice(&app, &payload);
            }
            return Ok(json!({"playing":true}));
        }
        "voice_ended" => {
            if let Some(id) = payload["jobId"].as_u64() {
                integration::stop_voice_job(&app, id);
            } else {
                integration::stop_untracked_voice(&app);
            }
            return Ok(json!({"playing":false}));
        }
        "drag_window" => {
            window.start_dragging().map_err(|error| error.to_string())?;
            return Ok(json!({}));
        }
        "come_over" | "call_over" => {
            integration::broadcast(&app, "callOver", &Value::Null, false);
            return Ok(json!({}));
        }
        "reset_position" => {
            layers::reset_pinned_position(&app);
            return Ok(integration::snapshot(&app));
        }
        "reload" => {
            layers::reload_all(&app);
            return Ok(json!({}));
        }
        "restart" => {
            integration::stop(&app);
            platform::shutdown();
            platform::release_instance();
            app.restart();
        }
        "album_capture" => {
            let value = crate::photos::capture(&app).await?;
            integration::notify(&app);
            return Ok(value);
        }
        "chat_image" => {
            let snapshot = services.companion.snapshot_for(false);
            let id = payload["id"].as_str().ok_or("沒有選擇圖片訊息")?;
            let name = snapshot["messages"]
                .as_array()
                .into_iter()
                .flatten()
                .find(|message| message["id"] == id)
                .and_then(|message| message["imageName"].as_str())
                .ok_or("找不到圖片訊息")?;
            let file = image_file(&app.state::<Shell>().data_dir.join("images"), name)?;
            return image_data(&file);
        }
        "album_image" | "album_export" => {
            let file = album_file(&app, payload["id"].as_str().ok_or("沒有選擇照片")?)?;
            if action == "album_export" {
                return native(&app, "export_file", json!({"sourcePath":file,"suggestedName":file.file_name().and_then(|name| name.to_str()).unwrap_or("miku.jpg")})).await;
            }
            let bytes = std::fs::read(&file).map_err(|_| "無法讀取照片")?;
            if bytes.len() > 16 * 1024 * 1024 {
                return Err("照片太大".into());
            }
            let mime = if file
                .extension()
                .is_some_and(|value| value.eq_ignore_ascii_case("png"))
            {
                "image/png"
            } else {
                "image/jpeg"
            };
            return Ok(json!({"image":format!("data:{mime};base64,{}",STANDARD.encode(bytes))}));
        }
        "songs_export" => {
            let document = services.companion.action("songs_export", payload)?;
            return native(&app, "export_json", json!({"document":serde_json::to_string_pretty(&document).map_err(|_| "無法匯出知識庫")?,"suggestedName":"miku-songs.json"})).await;
        }
        _ => {}
    }
    let value = if [
        "diary_generate",
        "songs_vocadb",
        "songs_update",
        "events_refresh",
        "ai_models",
        "models_refresh",
        "ai_test",
    ]
    .contains(&action.as_str())
    {
        services
            .companion
            .remote_action(
                if action == "ai_test" {
                    "ai_models"
                } else {
                    &action
                },
                payload,
            )
            .await?
    } else {
        services.companion.action(&action, payload)?
    };
    if let Some(lines) = value["lines"].as_array() {
        for line in lines {
            integration::broadcast(&app, "receiveReply", line, false);
            if let Some(rps) = line.get("rps") {
                integration::broadcast(&app, "playRPS", rps, false);
            }
        }
    }
    if let Some(game) = value.get("state") {
        if game["type"] == "rhythm" && action == "games_play" {
            integration::broadcast(&app, "rhythmBeat", &Value::Null, false);
        }
    }
    integration::configure(&app);
    integration::notify(&app);
    Ok(value)
}

#[tauri::command]
pub async fn desktop_platform(
    window: WebviewWindow,
    app: AppHandle,
    action: String,
    payload: Option<Value>,
) -> Result<Value, String> {
    panels::trusted(&window)?;
    let payload = payload.unwrap_or_else(|| json!({}));
    if ["ai_models", "ai_test"].contains(&action.as_str()) {
        return app
            .state::<Services>()
            .companion
            .remote_action("ai_models", payload)
            .await;
    }
    let allowed = [
        "voices",
        "pick_tda",
        "import_tda",
        "autostart",
        "weather",
        "update_check",
        "open_url",
        "open_data",
        "audio_devices",
        "system_info",
        "capabilities",
        "speak_status",
        "speech_status",
        "speech_stop",
        "listen_stop",
        "capture_screen",
    ];
    if !allowed.contains(&action.as_str()) {
        return Err("不支援這個平台動作".into());
    }
    if matches!(action.as_str(), "speech_stop" | "listen_stop") {
        check_call_owner(&app.state::<Services>(), &window)?;
    }
    let result = native(&app, &action, payload).await?;
    if action == "import_tda" {
        layers::reload_all(&app);
    }
    if action == "weather" {
        lock(&app.state::<Services>().environment)["weather"] = result.clone();
        integration::configure(&app);
    }
    Ok(result)
}

#[tauri::command]
pub async fn desktop_listen(
    window: WebviewWindow,
    app: AppHandle,
    language: String,
) -> Result<Value, String> {
    panels::trusted(&window)?;
    let state = app.state::<Services>();
    if state.listening.swap(true, Ordering::SeqCst) {
        return Err("麥克風正在使用中".into());
    }
    if let Err(error) = claim_ui(&state, &window, false) {
        state.listening.store(false, Ordering::SeqCst);
        return Err(error);
    }
    let result = native(
        &app,
        "listen_once",
        json!({"language":language,"userInitiated":true}),
    )
    .await;
    state.listening.store(false, Ordering::SeqCst);
    result
}

#[tauri::command]
pub async fn desktop_speak(
    window: WebviewWindow,
    app: AppHandle,
    text: String,
    language: String,
) -> Result<Value, String> {
    panels::trusted(&window)?;
    let settings = app.state::<Services>().companion.settings();
    if !speech_allowed(&app, &settings) {
        return Err("目前在安靜時段或已靜音".into());
    }
    claim_ui(&app.state::<Services>(), &window, false)?;
    *lock(&app.state::<Services>().voice_text) = text.clone();
    let job = native(&app, "speak", json!({"text":text,"language":language,"voice":settings["speechVoice"],"volume":settings["voiceVolume"]})).await?;
    if let Some(id) = job["jobId"].as_u64() {
        integration::register_voice_job(&app, id, &text);
    }
    Ok(job)
}

#[tauri::command]
pub async fn desktop_stop_speech(window: WebviewWindow, app: AppHandle) -> Result<Value, String> {
    panels::trusted(&window)?;
    check_call_owner(&app.state::<Services>(), &window)?;
    let result = native(&app, "speech_stop", json!({})).await;
    integration::stop_voice(&app);
    result
}

pub fn speech_allowed(app: &AppHandle, settings: &Value) -> bool {
    if settings["speechMuted"].as_bool().unwrap_or(false) {
        return false;
    }
    let services = app.state::<Services>();
    let context = lock(&services.environment).clone();
    if context["quiet"] == true
        || context["locked"] == true
        || context["sleeping"] == true
        || context["fullscreen"] == true
    {
        return false;
    }
    if services.companion.environment()["sleep"]["asleep"] == true {
        return false;
    }
    if settings["speechQuietEnabled"].as_bool() == Some(false) {
        return true;
    }
    let parse = |key: &str| {
        settings[key]
            .as_str()
            .and_then(|value| chrono::NaiveTime::parse_from_str(value, "%H:%M").ok())
    };
    let (Some(start), Some(end)) = (parse("quietStart"), parse("quietEnd")) else {
        return true;
    };
    if start == end {
        return true;
    }
    let now = chrono::Local::now().time();
    !(if start < end {
        now >= start && now < end
    } else {
        now >= start || now < end
    })
}

async fn local_voice(app: &AppHandle, payload: &Value) -> Result<Value, String> {
    let settings = app.state::<Services>().companion.settings();
    if !speech_allowed(app, &settings) {
        return Err("目前在安靜時段或已靜音".into());
    }
    let text = payload["text"].as_str().ok_or("沒有朗讀文字")?;
    if text.is_empty() || text.chars().count() > 10000 {
        return Err("朗讀文字長度不適合".into());
    }
    *lock(&app.state::<Services>().voice_text) = text.into();
    let endpoint = settings["ttsEndpoint"]
        .as_str()
        .unwrap_or("")
        .trim_end_matches('/');
    let mut url = tauri::Url::parse(endpoint).map_err(|_| "請先設定本機 TTS 端點")?;
    if !matches!(url.scheme(), "http" | "https")
        || !matches!(
            url.host_str(),
            Some("localhost" | "127.0.0.1" | "[::1]" | "::1")
        )
        || !url.username().is_empty()
        || url.password().is_some()
    {
        return Err("本機 TTS 只接受此電腦的 localhost 端點".into());
    }
    if !url.path().ends_with("/audio/speech") {
        url.set_path(&format!(
            "{}/audio/speech",
            url.path().trim_end_matches('/')
        ));
    }
    let client = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(std::time::Duration::from_secs(120))
        .build()
        .map_err(|_| "無法初始化語音連線")?;
    let response = client.post(url).json(&json!({"input":text,"model":settings["ttsModel"].as_str().unwrap_or(""),"voice":settings["ttsVoice"].as_str().unwrap_or(""),"response_format":"wav"})).send().await.map_err(|_| "本機語音服務連線失敗")?;
    if !response.status().is_success() {
        return Err(format!(
            "本機語音服務回覆 HTTP {}",
            response.status().as_u16()
        ));
    }
    let mime = response
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .unwrap_or("audio/wav")
        .split(';')
        .next()
        .unwrap_or("audio/wav")
        .to_owned();
    if !mime.starts_with("audio/") {
        return Err("語音服務沒有回傳音訊".into());
    }
    if response
        .content_length()
        .is_some_and(|size| size > 32 * 1024 * 1024)
    {
        return Err("音訊大小不適合播放".into());
    }
    let mut response = response;
    let mut bytes = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(|_| "音訊下載中斷")? {
        if bytes.len() + chunk.len() > 32 * 1024 * 1024 {
            return Err("音訊大小不適合播放".into());
        }
        bytes.extend_from_slice(&chunk);
    }
    if bytes.is_empty() || bytes.len() > 32 * 1024 * 1024 {
        return Err("音訊大小不適合播放".into());
    }
    Ok(json!({"audio":STANDARD.encode(bytes),"mimeType":mime}))
}

/// Background remarks use the same provider and playback lifecycle as chat replies.
pub async fn speak_background(
    app: &AppHandle,
    text: &str,
    language: &str,
) -> Result<Value, String> {
    let settings = app.state::<Services>().companion.settings();
    if !speech_allowed(app, &settings) {
        return Err("目前在安靜時段或已靜音".into());
    }
    if settings["speechProvider"] != "local" {
        let job = native(
            app,
            "speak",
            json!({"text":text,"language":language,"voice":settings["speechVoice"]}),
        )
        .await?;
        if let Some(id) = job["jobId"].as_u64() {
            integration::register_voice_job(app, id, text);
        }
        return Ok(job);
    }
    let audio = local_voice(app, &json!({"text":text,"language":language})).await?;
    let services = app.state::<Services>();
    if !speech_allowed(app, &services.companion.settings())
        || services.call_active.load(Ordering::SeqCst)
        || services.listening.load(Ordering::SeqCst)
        || services.chatting.load(Ordering::SeqCst)
    {
        return Err("背景語音已取消".into());
    }
    let bytes = STANDARD
        .decode(audio["audio"].as_str().ok_or("沒有語音內容")?)
        .map_err(|_| "音訊格式無效")?;
    if !bytes.starts_with(b"RIFF") || bytes.get(8..12) != Some(b"WAVE") {
        return Err("本機 TTS 必須回傳 WAV 音訊".into());
    }
    let directory = app.state::<Shell>().data_dir.join("speech-cache");
    std::fs::create_dir_all(&directory).map_err(|_| "無法建立語音快取")?;
    let file = directory.join(format!("{}.wav", uuid::Uuid::new_v4()));
    std::fs::write(&file, bytes).map_err(|_| "無法儲存語音快取")?;
    let result = native(app, "play_audio", json!({"path":file})).await;
    match result {
        Ok(job) => {
            if let Some(id) = job["jobId"].as_u64() {
                integration::register_voice_job(app, id, text);
            }
            let cleanup_app = app.clone();
            let job_id = job["jobId"].clone();
            tauri::async_runtime::spawn(async move {
                for _ in 0..2400 {
                    tokio::time::sleep(std::time::Duration::from_millis(250)).await;
                    let status =
                        native(&cleanup_app, "speak_status", json!({"jobId":job_id})).await;
                    if !status.as_ref().is_ok_and(|value| {
                        matches!(
                            value["state"].as_str(),
                            Some("starting" | "speaking" | "running")
                        )
                    }) {
                        break;
                    }
                }
                let _ = std::fs::remove_file(file);
            });
            Ok(job)
        }
        Err(error) => {
            let _ = std::fs::remove_file(file);
            Err(error)
        }
    }
}

async fn open_music(app: &AppHandle, request: &Value) -> Value {
    let query = request["query"].as_str().unwrap_or("");
    let platform = request["platform"].as_str().unwrap_or("youtube");
    let base = match platform {
        "spotify" => "https://open.spotify.com/search/",
        "appleMusic" => "https://music.apple.com/search",
        _ => "https://www.youtube.com/results",
    };
    let mut url = tauri::Url::parse(base).expect("fixed music URL");
    if !query.is_empty() {
        match platform {
            "spotify" => {
                url.path_segments_mut().unwrap().pop_if_empty().push(query);
            }
            "appleMusic" => {
                url.query_pairs_mut().append_pair("term", query);
            }
            _ => {
                url.query_pairs_mut().append_pair("search_query", query);
            }
        }
    }
    let target = request["officialURL"]
        .as_str()
        .filter(|_| platform == "youtube")
        .unwrap_or(url.as_str());
    match native(app, "open_url", json!({"url":target})).await {
        Ok(_) => {
            json!({"success":true,"action":"opened","playing":false,"platform":platform,"query":query,"url":target})
        }
        Err(error) => {
            json!({"success":false,"playing":false,"platform":platform,"query":query,"error":error})
        }
    }
}

fn album_file(app: &AppHandle, id: &str) -> Result<PathBuf, String> {
    let snapshot = app.state::<Services>().companion.snapshot();
    let entries = snapshot["album"]
        .as_array()
        .or_else(|| snapshot["album"]["entries"].as_array())
        .ok_or("相簿尚未就緒")?;
    let name = entries
        .iter()
        .find(|entry| entry["id"] == id)
        .and_then(|entry| entry["imageName"].as_str())
        .ok_or("找不到這張照片")?;
    image_file(&app.state::<Shell>().data_dir.join("album"), name)
}

fn image_file(directory: &Path, name: &str) -> Result<PathBuf, String> {
    if Path::new(name).file_name().and_then(|value| value.to_str()) != Some(name)
        || name.contains(['/', '\\', ':'])
    {
        return Err("照片路徑無效".into());
    }
    let directory = directory.canonicalize().map_err(|_| "圖片資料夾尚未建立")?;
    let file = directory
        .join(name)
        .canonicalize()
        .map_err(|_| "找不到照片檔案")?;
    if !file.starts_with(directory) || !file.is_file() {
        return Err("照片路徑無效".into());
    }
    Ok(file)
}

fn image_data(file: &Path) -> Result<Value, String> {
    let metadata = std::fs::metadata(file).map_err(|_| "無法讀取圖片")?;
    if metadata.len() > 16 * 1024 * 1024 {
        return Err("圖片太大".into());
    }
    let bytes = std::fs::read(file).map_err(|_| "無法讀取圖片")?;
    let mime = if file
        .extension()
        .is_some_and(|value| value.eq_ignore_ascii_case("png"))
    {
        "image/png"
    } else {
        "image/jpeg"
    };
    Ok(json!({"image":format!("data:{mime};base64,{}",STANDARD.encode(bytes))}))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn another_chat_window_cannot_take_over_an_active_call() {
        let calling = std::sync::atomic::AtomicBool::new(false);
        let mut owner = None;
        claim_owner(&mut owner, &calling, "app-chat", true).unwrap();
        assert!(claim_owner(&mut owner, &calling, "app-settings", false).is_err());
        assert!(claim_owner(&mut owner, &calling, "app-settings", true).is_err());
        assert_eq!(owner.as_deref(), Some("app-chat"));
        claim_owner(&mut owner, &calling, "app-chat", false).unwrap();
        calling.store(false, Ordering::SeqCst);
        claim_owner(&mut owner, &calling, "app-settings", false).unwrap();
        assert_eq!(owner.as_deref(), Some("app-settings"));
    }
}
