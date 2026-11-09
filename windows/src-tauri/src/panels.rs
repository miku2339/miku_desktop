//! Application windows share the bundled interface; desktop layers keep their own origin.

use tauri::{AppHandle, Manager, WebviewUrl, WebviewWindow, WebviewWindowBuilder};

const VIEWS: &[&str] = &["chat", "settings", "notebook", "album", "songs", "controls"];

fn bundled_url(url: &tauri::Url) -> bool {
    let origin = (url.scheme() == "tauri" && url.host_str() == Some("localhost"))
        || (matches!(url.scheme(), "http" | "https") && url.host_str() == Some("tauri.localhost"));
    origin
        && url.port().is_none()
        && url.username().is_empty()
        && url.password().is_none()
        && matches!(url.path(), "/" | "/index.html")
}

pub fn trusted(window: &WebviewWindow) -> Result<(), String> {
    let view = window.label().strip_prefix("app-").unwrap_or_default();
    let url = window.url().map_err(|_| "無法確認視窗來源".to_string())?;
    let local = bundled_url(&url);
    if !VIEWS.contains(&view) || !local {
        return Err("此視窗不能存取應用程式資料".into());
    }
    Ok(())
}

pub fn open(app: &AppHandle, view: &str) -> Result<(), String> {
    if !VIEWS.contains(&view) {
        return Err("找不到這個視窗".into());
    }
    let label = format!("app-{view}");
    if let Some(window) = app.get_webview_window(&label) {
        window.show().map_err(|error| error.to_string())?;
        if view != "controls" {
            window.set_focus().map_err(|error| error.to_string())?;
        }
        return Ok(());
    }
    let (title, width, height) = match view {
        "chat" => ("Miku", 420., 640.),
        "controls" => ("Miku Desktop", 320., 64.),
        "settings" => ("Miku · 設定", 900., 760.),
        "album" => ("Miku · 回憶相簿", 900., 760.),
        "songs" => ("Miku · 歌曲知識", 900., 760.),
        _ => ("Miku · 手帳", 900., 760.),
    };
    let (width, height) = if let Ok(Some(monitor)) = app.primary_monitor() {
        let area = monitor.work_area();
        (
            f64::min(
                width,
                f64::from(area.size.width) / monitor.scale_factor() - 40.,
            ),
            f64::min(
                height,
                f64::from(area.size.height) / monitor.scale_factor() - 80.,
            ),
        )
    } else {
        (width, height)
    };
    let target = format!("index.html#{view}");
    let builder = WebviewWindowBuilder::new(app, &label, WebviewUrl::App(target.into()))
        .title(title)
        .inner_size(width, height)
        .min_inner_size(
            if view == "controls" { 320. } else { 360. },
            if view == "controls" { 64. } else { 420. },
        )
        .decorations(view != "controls")
        .shadow(view != "controls")
        .resizable(view != "controls")
        .disable_drag_drop_handler()
        .skip_taskbar(view == "controls")
        .focused(view != "controls")
        .focusable(view != "controls")
        .on_navigation(bundled_url);
    #[cfg(windows)]
    let builder = if view == "controls" {
        let host = crate::desktop::icon_host()?;
        builder
            .transparent(true)
            .owner_raw(windows::Win32::Foundation::HWND(
                host as *mut std::ffi::c_void,
            ))
    } else {
        builder
    };
    let window = builder.build().map_err(|error| error.to_string())?;
    if view == "controls" {
        if let Ok(Some(monitor)) = app.primary_monitor() {
            let area = monitor.work_area();
            let height = (64. * monitor.scale_factor()) as i32;
            let position = tauri::PhysicalPosition::new(
                area.position.x + 24,
                area.position.y + area.size.height as i32 - height - 24,
            );
            let _ = window.set_position(position);
            #[cfg(windows)]
            if let Ok(hwnd) = window.hwnd() {
                let frame = crate::passthrough::Frame {
                    x: position.x,
                    y: position.y,
                    width: (320. * monitor.scale_factor()) as u32,
                    height: height as u32,
                };
                let app = app.clone();
                let handle = hwnd.0 as isize;
                let _ = app.run_on_main_thread(move || {
                    let _ = crate::desktop::position_above_icons(handle, frame);
                });
            }
        }
    }
    crate::layers::install_recovery(&window);
    window.on_window_event({
        let app = app.clone();
        let label = label.clone();
        move |event| {
            if matches!(event, tauri::WindowEvent::Destroyed) {
                if let Some(state) = app.try_state::<crate::integration::Services>() {
                    let owns_voice =
                        crate::lock(&state.ui_owner).as_deref() == Some(label.as_str());
                    if owns_voice {
                        state.cancel_chat.notify_waiters();
                        state
                            .call_active
                            .store(false, std::sync::atomic::Ordering::SeqCst);
                        crate::platform::shutdown();
                        crate::integration::stop_voice(&app);
                        crate::commands::resume_after_call(&app);
                        *crate::lock(&state.ui_owner) = None;
                    }
                }
            }
        }
    });
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn native_data_commands_only_trust_the_bundled_origin() {
        for url in [
            "http://tauri.localhost/index.html#chat",
            "tauri://localhost/#settings",
        ] {
            assert!(bundled_url(&tauri::Url::parse(url).unwrap()));
        }
        for url in [
            "http://localhost:8000/index.html",
            "https://example.com/index.html",
            "http://tauri.localhost:1234/",
            "http://miku.localhost/index.html",
            "http://tauri.localhost/other.html",
        ] {
            assert!(!bundled_url(&tauri::Url::parse(url).unwrap()));
        }
    }
}
