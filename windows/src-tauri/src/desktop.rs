//! Places the background behind the desktop icons and keeps the character owned by
//! the desktop, below application windows.
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

/// Keeps a desktop-owned character below applications without activating the desktop.
#[cfg(windows)]
pub fn position_above_icons(hwnd: isize, frame: Frame) -> Result<(), String> {
    use std::ptr::{null, null_mut};
    use windows_sys::Win32::Foundation::HWND;
    use windows_sys::Win32::UI::WindowsAndMessaging::{
        FindWindowExW, GetWindow, SetWindowPos, GW_OWNER, HWND_BOTTOM, SWP_FRAMECHANGED,
        SWP_NOACTIVATE, SWP_NOOWNERZORDER,
    };

    unsafe {
        let window = hwnd as HWND;
        let host = GetWindow(window, GW_OWNER);
        let defview: Vec<u16> = "SHELLDLL_DefView".encode_utf16().chain(Some(0)).collect();
        if host.is_null() || FindWindowExW(host, null_mut(), defview.as_ptr(), null()).is_null() {
            return Err("character desktop icon host is no longer available".into());
        }
        if SetWindowPos(
            window,
            HWND_BOTTOM,
            frame.x,
            frame.y,
            frame.width as i32,
            frame.height as i32,
            SWP_NOACTIVATE | SWP_NOOWNERZORDER | SWP_FRAMECHANGED,
        ) == 0 {
            return Err(format!("SetWindowPos above icons failed: {}", std::io::Error::last_os_error()));
        }
    }
    Ok(())
}

/// Changes mouse pass-through without showing or activating the character window.
#[cfg(windows)]
pub fn set_character_passthrough(hwnd: isize, ignore: bool) -> Result<(), String> {
    use windows_sys::Win32::Foundation::{GetLastError, SetLastError, HWND};
    use windows_sys::Win32::UI::WindowsAndMessaging::{
        GetWindowLongPtrW, SetWindowLongPtrW, SetWindowPos, GWL_EXSTYLE, HWND_BOTTOM,
        SWP_FRAMECHANGED, SWP_NOACTIVATE, SWP_NOMOVE, SWP_NOOWNERZORDER, SWP_NOSIZE,
        WS_EX_LAYERED, WS_EX_TRANSPARENT,
    };

    unsafe {
        let window = hwnd as HWND;
        SetLastError(0);
        let current = GetWindowLongPtrW(window, GWL_EXSTYLE);
        if current == 0 {
            let error = GetLastError();
            if error != 0 {
                return Err(format!("GetWindowLongPtrW for character failed: {}", std::io::Error::from_raw_os_error(error as i32)));
            }
        }
        let mask = (WS_EX_TRANSPARENT | WS_EX_LAYERED) as isize;
        let desired = if ignore { current | mask } else { current & !mask };
        if desired != current {
            SetLastError(0);
            if SetWindowLongPtrW(window, GWL_EXSTYLE, desired) == 0 {
                let error = GetLastError();
                if error != 0 {
                    return Err(format!("SetWindowLongPtrW for character failed: {}", std::io::Error::from_raw_os_error(error as i32)));
                }
            }
        }
        if SetWindowPos(
            window,
            HWND_BOTTOM,
            0,
            0,
            0,
            0,
            SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOOWNERZORDER | SWP_FRAMECHANGED,
        ) == 0 {
            return Err(format!("SetWindowPos for character pass-through failed: {}", std::io::Error::last_os_error()));
        }
    }
    Ok(())
}
