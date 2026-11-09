//! Application windows share the bundled interface; desktop layers keep their own origin.

use std::sync::{
    atomic::{AtomicU64, Ordering},
    Arc,
};
use std::time::Duration;
use tauri::{
    AppHandle, Manager, PhysicalPosition, WebviewUrl, WebviewWindow, WebviewWindowBuilder,
};

const VIEWS: &[&str] = &["chat", "settings", "notebook", "album", "songs", "controls"];

fn clamp_position(point: [i32; 2], size: [u32; 2], origin: [i32; 2], area: [u32; 2]) -> [i32; 2] {
    std::array::from_fn(|axis| {
        let minimum = i64::from(origin[axis]);
        let maximum = minimum + i64::from(area[axis].saturating_sub(size[axis]));
        i64::from(point[axis]).clamp(minimum, maximum) as i32
    })
}

fn position_panel(window: &WebviewWindow) -> Result<(), String> {
    let monitor = window
        .current_monitor()
        .ok()
        .flatten()
        .or_else(|| window.app_handle().primary_monitor().ok().flatten());
    if let Some(monitor) = monitor {
        let area = monitor.work_area();
        let size = window.outer_size().map_err(|error| error.to_string())?;
        let center = [
            (i64::from(area.position.x) + (i64::from(area.size.width) - i64::from(size.width)) / 2)
                as i32,
            (i64::from(area.position.y)
                + (i64::from(area.size.height) - i64::from(size.height)) / 2) as i32,
        ];
        let point = clamp_position(
            center,
            [size.width, size.height],
            [area.position.x, area.position.y],
            [area.size.width, area.size.height],
        );
        window
            .set_position(PhysicalPosition::new(point[0], point[1]))
            .map_err(|error| error.to_string())?;
    }
    Ok(())
}

fn position_controls(app: &AppHandle, window: &WebviewWindow) -> Result<(), String> {
    let saved = { crate::lock(&app.state::<crate::Shell>().settings).controls_position };
    let monitor = saved
        .and_then(|point| {
            app.available_monitors().ok()?.into_iter().find(|monitor| {
                let origin = monitor.position();
                let size = monitor.size();
                i64::from(point[0]) >= i64::from(origin.x)
                    && i64::from(point[1]) >= i64::from(origin.y)
                    && i64::from(point[0]) < i64::from(origin.x) + i64::from(size.width)
                    && i64::from(point[1]) < i64::from(origin.y) + i64::from(size.height)
            })
        })
        .or_else(|| app.primary_monitor().ok().flatten());
    if let Some(monitor) = monitor {
        let area = monitor.work_area();
        let mut size = window.outer_size().map_err(|error| error.to_string())?;
        let requested = saved.unwrap_or([
            area.position.x + 24,
            area.position.y + area.size.height as i32 - size.height as i32 - 24,
        ]);
        let mut point = clamp_position(
            requested,
            [size.width, size.height],
            [area.position.x, area.position.y],
            [area.size.width, area.size.height],
        );
        window
            .set_position(PhysicalPosition::new(point[0], point[1]))
            .map_err(|error| error.to_string())?;
        // Moving across monitors may change the physical size through DPI scaling.
        size = window.outer_size().map_err(|error| error.to_string())?;
        point = clamp_position(
            point,
            [size.width, size.height],
            [area.position.x, area.position.y],
            [area.size.width, area.size.height],
        );
        window
            .set_position(PhysicalPosition::new(point[0], point[1]))
            .map_err(|error| error.to_string())?;
        #[cfg(windows)]
        if let Ok(hwnd) = window.hwnd() {
            let frame = crate::passthrough::Frame {
                x: point[0],
                y: point[1],
                width: size.width,
                height: size.height,
            };
            let handle = hwnd.0 as isize;
            app.run_on_main_thread(move || {
                let _ = crate::desktop::position_above_icons(handle, frame);
            })
            .map_err(|error| error.to_string())?;
        }
    }
    Ok(())
}

fn floor_controls(window: &WebviewWindow) {
    #[cfg(windows)]
    {
        let target = window.clone();
        let _ = window.app_handle().run_on_main_thread(move || {
            if let Ok(hwnd) = target.hwnd() {
                if let Err(error) = crate::desktop::floor_owned_window(hwnd.0 as isize) {
                    target
                        .state::<crate::Shell>()
                        .diagnostics
                        .note("controls", &error);
                }
            }
        });
    }
    #[cfg(not(windows))]
    let _ = window;
}

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
        position_controls(app, &window)?;
    } else {
        position_panel(&window)?;
    }
    crate::layers::install_recovery(&window);
    window.on_window_event({
        let app = app.clone();
        let label = label.clone();
        let position_version = Arc::new(AtomicU64::new(0));
        move |event| {
            if label == "app-controls" {
                if let tauri::WindowEvent::Moved(position) = event {
                    let shell = app.state::<crate::Shell>();
                    crate::lock(&shell.settings).controls_position = Some([position.x, position.y]);
                    let version = position_version.fetch_add(1, Ordering::SeqCst) + 1;
                    let expected = position_version.clone();
                    let app = app.clone();
                    tauri::async_runtime::spawn(async move {
                        tokio::time::sleep(Duration::from_millis(500)).await;
                        if expected.load(Ordering::SeqCst) == version {
                            let shell = app.state::<crate::Shell>();
                            {
                                let settings = crate::lock(&shell.settings);
                                if expected.load(Ordering::SeqCst) == version {
                                    settings.save(&shell.data_dir);
                                }
                            }
                            if expected.load(Ordering::SeqCst) == version {
                                if let Some(window) = app.get_webview_window("app-controls") {
                                    floor_controls(&window);
                                }
                            }
                        }
                    });
                }
                if matches!(event, tauri::WindowEvent::Focused(false)) {
                    if let Some(window) = app.get_webview_window("app-controls") {
                        floor_controls(&window);
                    }
                }
            }
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
    fn positions_stay_inside_work_area_with_outer_window_size() {
        assert_eq!(
            clamp_position([90, 90], [900, 649], [0, 0], [1200, 700]),
            [90, 51]
        );
        assert_eq!(
            clamp_position([-100, 680], [320, 64], [-1920, 0], [1920, 700]),
            [-320, 636]
        );
        assert_eq!(
            clamp_position([600, 600], [2000, 900], [0, 0], [1200, 700]),
            [0, 0]
        );
    }
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
