//! The two desktop layers, one set per monitor, like `WallpaperWindowController`:
//! - background (`?layer=background`): attached under WorkerW, behind the desktop icons;
//! - character (`?layer=character`): transparent window owned by the desktop, click-through
//!   except over Miku (passthrough.rs), below application windows.

use serde_json::Value;
use tauri::webview::PageLoadEvent;
use tauri::{
    AppHandle, Manager, PhysicalPosition, PhysicalSize, Webview, WebviewUrl, WebviewWindow,
    WebviewWindowBuilder,
};

use crate::bridge::{call_page, eval_page};
use crate::passthrough::{CharacterLayer, Frame};
use crate::{desktop, lock, protocol, Shell};

pub const BACKGROUND_PREFIX: &str = "bg-";
pub const CHARACTER_PREFIX: &str = "char-";

/// The monitors as the shell last laid them out.
pub fn monitor_frames(app: &AppHandle) -> Vec<Frame> {
    app.available_monitors()
        .unwrap_or_default()
        .iter()
        .map(|monitor| {
            let position = monitor.position();
            let size = monitor.size();
            Frame { x: position.x, y: position.y, width: size.width, height: size.height }
        })
        .collect()
}

/// Creates both layers on every monitor. Safe from the main thread during setup or from a
/// background thread; never from a synchronous command (WebView2 would deadlock).
pub fn create_all(app: &AppHandle) {
    let shell = app.state::<Shell>();
    let frames = monitor_frames(app);
    let generation = {
        let mut layers = lock(&shell.layers);
        layers.generation += 1;
        layers.monitors = frames.clone();
        layers.generation
    };
    for (index, frame) in frames.iter().enumerate() {
        let id = format!("{generation}-{index}");
        if let Err(error) = create_background(app, &format!("{BACKGROUND_PREFIX}{id}"), *frame) {
            shell.diagnostics.note("layers", &format!("background {id}: {error}"));
        }
        // Registered before the window exists: its page may finish loading before build() returns.
        let label = format!("{CHARACTER_PREFIX}{id}");
        lock(&shell.layers).characters.insert(label.clone(), CharacterLayer::new(*frame));
        if let Err(error) = create_character(app, &label, *frame) {
            lock(&shell.layers).characters.remove(&label);
            shell.diagnostics.note("layers", &format!("character {id}: {error}"));
        }
    }
}

/// Monitors were added, removed or rearranged: start over with a fresh set of windows.
pub fn rebuild_if_monitors_changed(app: &AppHandle) {
    let frames = monitor_frames(app);
    if frames.is_empty() {
        return;
    }
    let shell = app.state::<Shell>();
    if lock(&shell.layers).monitors == frames {
        return;
    }
    destroy_all(app);
    create_all(app);
}

pub fn destroy_all(app: &AppHandle) {
    let shell = app.state::<Shell>();
    lock(&shell.layers).characters.clear();
    for (label, window) in app.webview_windows() {
        if label.starts_with(BACKGROUND_PREFIX) || label.starts_with(CHARACTER_PREFIX) {
            let _ = window.destroy();
        }
    }
}

pub fn character_windows(app: &AppHandle) -> Vec<WebviewWindow> {
    app.webview_windows()
        .into_iter()
        .filter(|(label, _)| label.starts_with(CHARACTER_PREFIX))
        .map(|(_, window)| window)
        .collect()
}

fn create_background(app: &AppHandle, label: &str, frame: Frame) -> tauri::Result<()> {
    let window = WebviewWindowBuilder::new(app, label, WebviewUrl::External(protocol::layer_url("background")))
        .title("Miku Desktop Background")
        .decorations(false)
        .resizable(false)
        .shadow(false)
        .skip_taskbar(true)
        .focused(false)
        .visible(false)
        .build()?;
    place(&window, frame)?;
    window.set_ignore_cursor_events(true)?;

    #[cfg(windows)]
    {
        let hwnd = window.hwnd()?.0 as isize;
        let target = window.clone();
        app.run_on_main_thread(move || {
            if let Err(error) = desktop::attach_behind_icons(hwnd, frame) {
                // Never leave an opaque full-screen window over the desktop.
                target.state::<Shell>().diagnostics.note("layers", &format!("{}: {error}", target.label()));
                let _ = target.destroy();
            }
        })?;
    }
    #[cfg(not(windows))]
    {
        // Development on another OS: no desktop layer to attach to; keep it hidden.
        let _ = desktop::attach_behind_icons(0, frame);
    }
    Ok(())
}

fn create_character(app: &AppHandle, label: &str, frame: Frame) -> tauri::Result<()> {
    let builder = WebviewWindowBuilder::new(app, label, WebviewUrl::External(protocol::layer_url("character")))
        .title("Miku Desktop Character")
        .decorations(false)
        .resizable(false)
        .shadow(false)
        .skip_taskbar(true)
        .focusable(false)
        .focused(false)
        .visible(false);
    #[cfg(windows)]
    let builder = {
        let host = desktop::icon_host().map_err(std::io::Error::other)?;
        // Keep a top-level window for transparency without clipping the desktop icon view.
        builder.owner_raw(windows::Win32::Foundation::HWND(host as *mut std::ffi::c_void))
    };
    // macOS needs the private-API feature for this; the Windows shell does not.
    #[cfg(not(target_os = "macos"))]
    let builder = builder.transparent(true);
    let window = builder.build()?;
    set_character_passthrough(&window, true)?;
    #[cfg(windows)]
    {
        let hwnd = window.hwnd()?.0 as isize;
        let target = window.clone();
        app.run_on_main_thread(move || {
            let result = desktop::position_above_icons(hwnd, frame)
                .and_then(|()| target.show().map_err(|error| error.to_string()))
                .and_then(|()| desktop::set_character_passthrough(hwnd, true));
            if let Err(error) = result {
                let shell = target.state::<Shell>();
                lock(&shell.layers).characters.remove(target.label());
                shell.diagnostics.note("layers", &format!("{}: {error}", target.label()));
                let _ = target.destroy();
            }
        })?;
    }
    #[cfg(not(windows))]
    {
        place(&window, frame)?;
        window.show()?;
    }
    Ok(())
}

fn place(window: &WebviewWindow, frame: Frame) -> tauri::Result<()> {
    window.set_position(PhysicalPosition::new(frame.x, frame.y))?;
    window.set_size(PhysicalSize::new(frame.width, frame.height))
}

pub fn set_character_passthrough(window: &WebviewWindow, ignore: bool) -> tauri::Result<()> {
    #[cfg(windows)]
    {
        let target = window.clone();
        window.app_handle().run_on_main_thread(move || {
            let result = target.hwnd().map_err(|error| error.to_string())
                .and_then(|hwnd| desktop::set_character_passthrough(hwnd.0 as isize, ignore));
            if let Err(error) = result {
                target.state::<Shell>().diagnostics.note("layers", &format!("{}: {error}", target.label()));
            }
        })
    }
    #[cfg(not(windows))]
    window.set_ignore_cursor_events(ignore)
}

/// `on_page_load`: macOS does the same in `webView(_:didFinish:)` and on content-process restarts.
pub fn page_loaded(webview: &Webview, event: PageLoadEvent) {
    let label = webview.label().to_string();
    let app = webview.app_handle();
    let Some(window) = app.get_webview_window(&label) else { return };
    let shell = app.state::<Shell>();
    let is_character = label.starts_with(CHARACTER_PREFIX);

    match event {
        PageLoadEvent::Started => {
            if !is_character {
                return;
            }
            let pass_through = {
                let mut layers = lock(&shell.layers);
                let Some(layer) = layers.characters.get_mut(&label) else { return };
                layer.reset();
                layer.want_ignore(true)
            };
            if pass_through {
                let _ = set_character_passthrough(&window, true);
            }
        }
        PageLoadEvent::Finished => {
            let interactive = is_character && lock(&shell.settings).interactive_mode;
            configure_page(&window, &shell, interactive);
            if is_character {
                if let Some(layer) = lock(&shell.layers).characters.get_mut(&label) {
                    layer.ready = true;
                }
            }
            // TODO(stages 3–5): weather, sun times, sleep schedule, relationship, special days
            // and music, which macOS pushes 1.5 s after the page finishes loading.
        }
    }
}

/// Same start-up script as macOS `configurePage`: waits for the page module, then sets it up.
fn configure_page(window: &WebviewWindow, shell: &Shell, interactive: bool) {
    let (scene, pinned) = {
        let settings = lock(&shell.settings);
        (Value::from(settings.selected_scene.clone()), settings.pinned_anchor.map(Value::from).unwrap_or(Value::Null))
    };
    let script = format!(
        "(function waitForMiku(attempt) {{
  const companion = window.mikuCompanion;
  if (companion) {{
    companion.setInteractive({interactive});
    companion.setPinnedAnchor?.({pinned});
    if (companion.setScene({scene}) !== false) return;
  }}
  if (attempt < 100) setTimeout(() => waitForMiku(attempt + 1), 100);
}})(0)"
    );
    eval_page(window, &script);
}

/// Tray menu: turn touching Miku on or off for every character layer.
pub fn set_interactive(app: &AppHandle, enabled: bool) {
    let shell = app.state::<Shell>();
    {
        let mut settings = lock(&shell.settings);
        settings.interactive_mode = enabled;
        settings.save(&shell.data_dir);
    }
    for window in character_windows(app) {
        if !enabled {
            let _ = set_character_passthrough(&window, true);
            if let Some(layer) = lock(&shell.layers).characters.get_mut(window.label()) {
                layer.ignoring = Some(true);
            }
        }
        call_page(&window, "setInteractive", &Value::from(enabled));
    }
}

/// Tray menu: forget where she was dragged to (macOS `resetPinnedPosition`).
pub fn reset_pinned_position(app: &AppHandle) {
    let shell = app.state::<Shell>();
    {
        let mut settings = lock(&shell.settings);
        settings.pinned_anchor = None;
        settings.save(&shell.data_dir);
    }
    for window in character_windows(app) {
        call_page(&window, "setPinnedAnchor", &Value::Null);
    }
}

/// Tray menu: reload both layers on every monitor.
pub fn reload_all(app: &AppHandle) {
    for (label, window) in app.webview_windows() {
        if label.starts_with(BACKGROUND_PREFIX) || label.starts_with(CHARACTER_PREFIX) {
            eval_page(&window, "window.location.reload()");
        }
    }
}
