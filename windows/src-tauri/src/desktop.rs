//! Places the background behind the desktop icons and the character above them, within
//! the desktop's own window hierarchy.
//!
//! Asking Progman with the undocumented message 0x052C makes Explorer create a `WorkerW`
//! window between the wallpaper and the icons (`SHELLDLL_DefView`); the background window
//! becomes a child of that WorkerW. Two layouts exist:
//! - Windows 10 / Windows 11 before 24H2: the icons live in a top-level WorkerW; the WorkerW
//!   to use is the next top-level sibling after it.
//! - Windows 11 24H2 and later: both `SHELLDLL_DefView` and the WorkerW are children of Progman.

use crate::passthrough::Frame;

#[cfg(windows)]
pub fn attach_behind_icons(hwnd: isize, frame: Frame) -> Result<(), String> {
    use std::ffi::c_void;
    use std::ptr::{null, null_mut};
    use windows_sys::Win32::Foundation::{BOOL, HWND, LPARAM, RECT};
    use windows_sys::Win32::UI::WindowsAndMessaging::{
        EnumWindows, FindWindowExW, FindWindowW, GetWindowLongPtrW, GetWindowRect, SendMessageTimeoutW,
        SetLayeredWindowAttributes, SetParent, SetWindowLongPtrW, SetWindowPos, GWL_STYLE, LWA_ALPHA,
        SMTO_NORMAL, SWP_FRAMECHANGED, SWP_NOACTIVATE, SWP_NOZORDER, SWP_SHOWWINDOW, WS_CAPTION, WS_CHILD,
        WS_POPUP, WS_SYSMENU, WS_THICKFRAME,
    };

    fn wide(text: &str) -> Vec<u16> {
        text.encode_utf16().chain(Some(0)).collect()
    }

    unsafe extern "system" fn find_worker(top: HWND, found: LPARAM) -> BOOL {
        let defview = FindWindowExW(top, null_mut(), wide("SHELLDLL_DefView").as_ptr(), null());
        if defview.is_null() {
            return 1;
        }
        let worker = FindWindowExW(null_mut(), top, wide("WorkerW").as_ptr(), null());
        if worker.is_null() {
            return 1;
        }
        *(found as *mut HWND) = worker;
        0
    }

    unsafe {
        let progman = FindWindowW(wide("Progman").as_ptr(), null());
        if progman.is_null() {
            return Err("Progman not found (is Explorer running?)".into());
        }
        let mut ignored: usize = 0;
        SendMessageTimeoutW(progman, 0x052C, 0xD, 0x1, SMTO_NORMAL, 1000, &mut ignored);

        let icons_in_progman = !FindWindowExW(progman, null_mut(), wide("SHELLDLL_DefView").as_ptr(), null()).is_null();
        let child_worker = FindWindowExW(progman, null_mut(), wide("WorkerW").as_ptr(), null());
        let host: HWND = if icons_in_progman && !child_worker.is_null() {
            child_worker
        } else {
            let mut found: HWND = null_mut();
            EnumWindows(Some(find_worker), &mut found as *mut HWND as LPARAM);
            found
        };
        if host.is_null() {
            return Err("WorkerW behind the desktop icons not found".into());
        }

        let window = hwnd as *mut c_void as HWND;
        // The click-through background is layered and needs an explicit opacity.
        if SetLayeredWindowAttributes(window, 0, 255, LWA_ALPHA) == 0 {
            return Err(format!(
                "SetLayeredWindowAttributes for background failed: {}",
                std::io::Error::last_os_error()
            ));
        }
        // A child window: no popup frame, positioned in the host's coordinates.
        let mut style = GetWindowLongPtrW(window, GWL_STYLE);
        style &= !((WS_POPUP | WS_CAPTION | WS_THICKFRAME | WS_SYSMENU) as isize);
        style |= WS_CHILD as isize;
        SetWindowLongPtrW(window, GWL_STYLE, style);
        if SetParent(window, host).is_null() {
            return Err("SetParent to WorkerW failed".into());
        }

        let mut host_rect = RECT { left: 0, top: 0, right: 0, bottom: 0 };
        GetWindowRect(host, &mut host_rect);
        let placed = SetWindowPos(
            window,
            null_mut(),
            frame.x - host_rect.left,
            frame.y - host_rect.top,
            frame.width as i32,
            frame.height as i32,
            SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED | SWP_SHOWWINDOW,
        );
        if placed == 0 {
            return Err("SetWindowPos under WorkerW failed".into());
        }
    }
    Ok(())
}

#[cfg(not(windows))]
pub fn attach_behind_icons(_hwnd: isize, _frame: Frame) -> Result<(), String> {
    Err("the desktop background layer is only available on Windows".into())
}

/// The desktop window whose children include the icon view.
#[cfg(windows)]
pub fn icon_host() -> Result<isize, String> {
    use std::ptr::{null, null_mut};
    use windows_sys::Win32::UI::WindowsAndMessaging::{FindWindowExW, FindWindowW};

    let wide = |text: &str| text.encode_utf16().chain(Some(0)).collect::<Vec<_>>();
    let defview = wide("SHELLDLL_DefView");
    let worker = wide("WorkerW");
    unsafe {
        let progman = FindWindowW(wide("Progman").as_ptr(), null());
        if !progman.is_null() && !FindWindowExW(progman, null_mut(), defview.as_ptr(), null()).is_null() {
            return Ok(progman as isize);
        }
        let mut host = FindWindowExW(null_mut(), null_mut(), worker.as_ptr(), null());
        while !host.is_null() {
            if !FindWindowExW(host, null_mut(), defview.as_ptr(), null()).is_null() {
                return Ok(host as isize);
            }
            host = FindWindowExW(null_mut(), host, worker.as_ptr(), null());
        }
    }
    Err("desktop icon host not found (is Explorer running?)".into())
}

/// Positions a character child above its sibling icon view without activating the desktop.
#[cfg(windows)]
pub fn position_above_icons(hwnd: isize, frame: Frame) -> Result<(), String> {
    use std::ptr::{null, null_mut};
    use windows_sys::Win32::Foundation::{HWND, RECT};
    use windows_sys::Win32::UI::WindowsAndMessaging::{
        FindWindowExW, GetParent, GetWindowRect, SetWindowPos, HWND_TOP, SWP_FRAMECHANGED,
        SWP_NOACTIVATE,
    };

    unsafe {
        let window = hwnd as HWND;
        let host = GetParent(window);
        let defview: Vec<u16> = "SHELLDLL_DefView".encode_utf16().chain(Some(0)).collect();
        if host.is_null() || FindWindowExW(host, null_mut(), defview.as_ptr(), null()).is_null() {
            return Err("character desktop icon host is no longer available".into());
        }
        let mut host_rect = RECT { left: 0, top: 0, right: 0, bottom: 0 };
        if GetWindowRect(host, &mut host_rect) == 0 {
            return Err(format!("GetWindowRect for icon host failed: {}", std::io::Error::last_os_error()));
        }
        if SetWindowPos(
            window,
            HWND_TOP,
            frame.x - host_rect.left,
            frame.y - host_rect.top,
            frame.width as i32,
            frame.height as i32,
            SWP_NOACTIVATE | SWP_FRAMECHANGED,
        ) == 0 {
            return Err(format!("SetWindowPos above icons failed: {}", std::io::Error::last_os_error()));
        }
    }
    Ok(())
}
