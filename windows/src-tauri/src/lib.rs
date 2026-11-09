//! Miku Desktop for Windows with shared character rendering and native companion services.

mod bridge;
mod commands;
mod companion;
mod desktop;
mod integration;
mod layers;
mod panels;
mod passthrough;
mod photos;
mod platform;
mod protocol;
mod scheduler;
mod settings;

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard};
use std::time::{Duration, Instant};

use tauri::menu::{CheckMenuItem, Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::{AppHandle, Manager, RunEvent};

use passthrough::{Action, CharacterLayer, Frame};
use protocol::PageFiles;
use settings::{Diagnostics, Settings};

pub struct Shell {
    pub data_dir: PathBuf,
    pub diagnostics: Diagnostics,
    pub settings: Mutex<Settings>,
    pub layers: Mutex<Layers>,
}

#[derive(Default)]
pub struct Layers {
    /// Bumped on every rebuild so new window labels never collide with closing ones.
    pub generation: u64,
    pub monitors: Vec<Frame>,
    /// Character windows by label.
    pub characters: HashMap<String, CharacterLayer>,
    pub next_seq: u64,
}

/// Never hold one of these while calling a Tauri getter: getters wait for the main thread,
/// which may itself be waiting for the lock in a command.
pub(crate) fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

const MONITOR_CHECK: Duration = Duration::from_secs(2);

pub fn run() {
    if let Err(error) = platform::claim_instance() {
        eprintln!("Miku Desktop: {error}");
        return;
    }
    configure_motion();
    let app = tauri::Builder::default()
        .register_uri_scheme_protocol(protocol::SCHEME, |ctx, request| {
            match ctx.app_handle().try_state::<PageFiles>() {
                Some(files) => files.respond(&request),
                None => protocol::not_found(),
            }
        })
        .on_page_load(|webview, payload| layers::page_loaded(webview, payload.event()))
        .invoke_handler(tauri::generate_handler![bridge::miku_message, bridge::miku_hit_result,
            commands::desktop_snapshot, commands::desktop_open, commands::desktop_update_settings,
            commands::desktop_send_message, commands::desktop_action, commands::desktop_platform,
            commands::desktop_listen, commands::desktop_speak, commands::desktop_stop_speech])
        .setup(|app| {
            let handle = app.handle().clone();
            let data_dir = app.path().data_dir()?.join("MikuDesktop");
            let diagnostics = Diagnostics::new(&data_dir);
            let root = wallpaper_root(&handle);
            if !root.join("companion/index.html").is_file() {
                diagnostics.note("setup", &format!("shared page not found under {}", root.display()));
            }
            let imported_tda = data_dir.join("CharacterModels").join("tda");
            app.manage(PageFiles::new(root, imported_tda));
            if let Ok(files) = std::fs::read_dir(data_dir.join("speech-cache")) {
                for entry in files.flatten() {
                    let file = entry.path();
                    if file.extension().is_some_and(|extension| extension == "wav")
                        && file.file_stem().and_then(|stem| stem.to_str()).is_some_and(|stem| uuid::Uuid::parse_str(stem).is_ok()) {
                        let _ = std::fs::remove_file(file);
                    }
                }
            }
            let services = integration::Services::new(data_dir.clone());
            if !data_dir.join("companion-settings.json").exists()
                && std::env::var("WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS").unwrap_or_default().contains("--force-prefers-no-reduced-motion") {
                let _ = services.companion.update_settings(serde_json::json!({"fullMotion":true}));
            }
            app.manage(services);
            app.manage(Shell {
                settings: Mutex::new(Settings::load(&data_dir)),
                layers: Mutex::new(Layers::default()),
                diagnostics,
                data_dir,
            });
            build_tray(&handle)?;
            layers::create_all(&handle);
            let _ = panels::open(&handle, "controls");
            scheduler::start(handle.clone());
            spawn_pointer_polling(handle);
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("error while building Miku Desktop");

    app.run(|app, event| {
        // The layers have no close button; keep running in the tray if Explorer takes a
        // layer down with it. Only the tray's Quit (an explicit exit code) ends the app.
        match event {
            RunEvent::ExitRequested { api, code, .. } if code.is_none() => api.prevent_exit(),
            RunEvent::Exit => {
                integration::stop(app);
                platform::shutdown();
                platform::release_instance();
            }
            _ => {}
        }
    });
}

fn configure_motion() {
    #[cfg(windows)]
    if let Some(data) = std::env::var_os("APPDATA") {
        let file = PathBuf::from(data).join("MikuDesktop/companion-settings.json");
        let setting = std::fs::read(file).ok().and_then(|bytes| serde_json::from_slice::<serde_json::Value>(&bytes).ok());
        if let Some(enabled) = setting.as_ref().and_then(|value| value["fullMotion"].as_bool()) {
            let current = std::env::var("WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS").unwrap_or_default();
            let mut flags: Vec<_> = current.split_whitespace().filter(|flag| !flag.starts_with("--force-prefers-reduced-motion") && !flag.starts_with("--force-prefers-no-reduced-motion")).map(String::from).collect();
            if enabled { flags.push("--force-prefers-no-reduced-motion".into()); }
            std::env::set_var("WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS", flags.join(" "));
        }
    }
}

/// `Wallpaper/` with the shared page and assets. Debug builds read the repository's copy so
/// edits to the page show on reload; release builds read the bundled resources.
/// `MIKU_WALLPAPER_DIR` overrides both.
fn wallpaper_root(app: &AppHandle) -> PathBuf {
    if let Some(dir) = std::env::var_os("MIKU_WALLPAPER_DIR") {
        return PathBuf::from(dir);
    }
    let repository = Path::new(env!("CARGO_MANIFEST_DIR")).join("..").join("..").join("Wallpaper");
    if cfg!(debug_assertions) && repository.join("companion").join("index.html").is_file() {
        return repository;
    }
    app.path()
        .resource_dir()
        .map(|dir| dir.join("Wallpaper"))
        .unwrap_or(repository)
}

fn build_tray(app: &AppHandle) -> tauri::Result<()> {
    let interactive = lock(&app.state::<Shell>().settings).interactive_mode;
    let touch = CheckMenuItem::with_id(app, "interactive", "可以觸碰 Miku", true, interactive, None::<&str>)?;
    let reset = MenuItem::with_id(app, "reset-position", "Miku 回到原位", true, None::<&str>)?;
    let reload = MenuItem::with_id(app, "reload", "重新載入桌面", true, None::<&str>)?;
    let chat = MenuItem::with_id(app, "chat", "和 Miku 聊天", true, None::<&str>)?;
    let notebook = MenuItem::with_id(app, "notebook", "手帳", true, None::<&str>)?;
    let settings = MenuItem::with_id(app, "settings", "設定", true, None::<&str>)?;
    let album = MenuItem::with_id(app, "album", "回憶相簿", true, None::<&str>)?;
    let songs = MenuItem::with_id(app, "songs", "歌曲知識", true, None::<&str>)?;
    let controls = MenuItem::with_id(app, "controls", "桌面控制", true, None::<&str>)?;
    let come = MenuItem::with_id(app, "come", "Miku 過來一下", true, None::<&str>)?;
    let separator = PredefinedMenuItem::separator(app)?;
    let quit = MenuItem::with_id(app, "quit", "結束 Miku Desktop", true, None::<&str>)?;
    let menu = Menu::with_items(app, &[&chat, &notebook, &settings, &album, &songs, &controls, &come, &separator, &touch, &reset, &reload, &quit])?;

    let mut tray = TrayIconBuilder::with_id("main").tooltip("Miku Desktop").menu(&menu);
    if let Some(icon) = app.default_window_icon() {
        tray = tray.icon(icon.clone());
    }
    let touch_item = touch.clone();
    tray.on_menu_event(move |app, event| match event.id.as_ref() {
        "interactive" => layers::set_interactive(app, touch_item.is_checked().unwrap_or(true)),
        "reset-position" => layers::reset_pinned_position(app),
        "reload" => layers::reload_all(app),
        "chat" | "notebook" | "settings" | "album" | "songs" | "controls" => { let _ = panels::open(app, event.id.as_ref()); }
        "come" => integration::broadcast(app, "callOver", &serde_json::Value::Null, false),
        "quit" => app.exit(0),
        _ => {}
    })
    .build(app)?;
    Ok(())
}

/// The 30 Hz pointer poll (macOS `startPointerPolling`), plus a slower check for monitor changes.
fn spawn_pointer_polling(app: AppHandle) {
    let spawned = std::thread::Builder::new().name("miku-pointer".into()).spawn(move || {
        let mut last_monitor_check = Instant::now();
        loop {
            std::thread::sleep(passthrough::POLL_INTERVAL);
            poll_pointer(&app);
            if last_monitor_check.elapsed() >= MONITOR_CHECK {
                last_monitor_check = Instant::now();
                layers::rebuild_if_monitors_changed(&app);
            }
        }
    });
    if let Err(error) = spawned {
        eprintln!("Miku Desktop: pointer polling did not start: {error}");
    }
}

fn poll_pointer(app: &AppHandle) {
    let shell = app.state::<Shell>();
    let interactive = lock(&shell.settings).interactive_mode;
    let cursor = app.cursor_position().ok().map(|position| (position.x, position.y));
    let now = Instant::now();

    let mut actions: Vec<(String, Action)> = Vec::new();
    {
        let mut layers = lock(&shell.layers);
        let Layers { characters, next_seq, .. } = &mut *layers;
        for (label, layer) in characters.iter_mut() {
            for action in passthrough::decide(layer, interactive, cursor, now, next_seq) {
                actions.push((label.clone(), action));
            }
        }
    }

    for (label, action) in actions {
        let Some(window) = app.get_webview_window(&label) else { continue };
        match action {
            Action::SetIgnore(ignore) => {
                let _ = layers::set_character_passthrough(&window, ignore);
            }
            Action::EndHover => bridge::eval_page(&window, "window.mikuCompanion?.endHover?.()"),
            Action::HitTest { seq, x, y } => {
                bridge::eval_page(&window, &passthrough::hit_test_script(seq, x, y));
            }
        }
    }
}
