use serde_json::{json, Value};

#[cfg(windows)]
static INSTANCE: std::sync::Mutex<Option<isize>> = std::sync::Mutex::new(None);

#[cfg(windows)]
pub fn system_snapshot(include_activity: bool) -> Value {
    use windows_sys::Win32::Foundation::{CloseHandle, RECT};
    use windows_sys::Win32::Graphics::Gdi::{
        GetMonitorInfoW, MonitorFromWindow, MONITORINFO, MONITOR_DEFAULTTONEAREST,
    };
    use windows_sys::Win32::System::Power::{GetSystemPowerStatus, SYSTEM_POWER_STATUS};
    use windows_sys::Win32::System::SystemInformation::GetTickCount64;
    use windows_sys::Win32::System::Threading::{
        OpenProcess, QueryFullProcessImageNameW, PROCESS_QUERY_LIMITED_INFORMATION,
    };
    use windows_sys::Win32::UI::Input::KeyboardAndMouse::{GetLastInputInfo, LASTINPUTINFO};
    use windows_sys::Win32::UI::Shell::{SHQueryUserNotificationState, QUNS_ACCEPTS_NOTIFICATIONS};
    use windows_sys::Win32::UI::WindowsAndMessaging::*;
    unsafe {
        let mut idle = LASTINPUTINFO {
            cbSize: std::mem::size_of::<LASTINPUTINFO>() as u32,
            dwTime: 0,
        };
        let idle_seconds = if GetLastInputInfo(&mut idle) != 0 {
            Some(((GetTickCount64() as u32).wrapping_sub(idle.dwTime)) as f64 / 1000.0)
        } else {
            None
        };
        let mut notification = 0;
        let notification_known = SHQueryUserNotificationState(&mut notification) >= 0;
        let mut power: SYSTEM_POWER_STATUS = std::mem::zeroed();
        let power = if GetSystemPowerStatus(&mut power) != 0 {
            json!({"onAC":power.ACLineStatus == 1,"batteryPercent":if power.BatteryLifePercent <= 100 {Some(power.BatteryLifePercent)} else {None},"batterySaver":power.SystemStatusFlag == 1})
        } else {
            Value::Null
        };
        let mut foreground = Value::Null;
        let mut fullscreen = false;
        let hwnd = GetForegroundWindow();
        if !hwnd.is_null() {
            let mut rect: RECT = std::mem::zeroed();
            let mut monitor: MONITORINFO = std::mem::zeroed();
            monitor.cbSize = std::mem::size_of::<MONITORINFO>() as u32;
            if GetWindowRect(hwnd, &mut rect) != 0
                && GetMonitorInfoW(
                    MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST),
                    &mut monitor,
                ) != 0
            {
                fullscreen = rect.left <= monitor.rcMonitor.left
                    && rect.top <= monitor.rcMonitor.top
                    && rect.right >= monitor.rcMonitor.right
                    && rect.bottom >= monitor.rcMonitor.bottom;
                let mut class = [0u16; 128];
                let count = GetClassNameW(hwnd, class.as_mut_ptr(), class.len() as i32);
                if ["Progman", "WorkerW"]
                    .contains(&String::from_utf16_lossy(&class[..count.max(0) as usize]).as_str())
                {
                    fullscreen = false;
                }
            }
            if include_activity {
                let mut title = [0u16; 1024];
                let count = GetWindowTextW(hwnd, title.as_mut_ptr(), title.len() as i32);
                let mut pid = 0;
                GetWindowThreadProcessId(hwnd, &mut pid);
                let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
                let mut app = None;
                if !process.is_null() {
                    let mut path = [0u16; 32768];
                    let mut size = path.len() as u32;
                    if QueryFullProcessImageNameW(process, 0, path.as_mut_ptr(), &mut size) != 0 {
                        app = String::from_utf16_lossy(&path[..size as usize])
                            .rsplit('\\')
                            .next()
                            .map(str::to_owned);
                    }
                    CloseHandle(process);
                }
                foreground = json!({"app":app,"title":String::from_utf16_lossy(&title[..count.max(0) as usize]),"pid":pid});
            }
        }
        let display = super::monitor::snapshot();
        let microphone = super::audio::snapshot();
        let quiet = if microphone["inUse"] == true {
            Some(true)
        } else if notification_known {
            Some(notification != QUNS_ACCEPTS_NOTIFICATIONS)
        } else {
            None
        };
        json!({"platform":"windows","foreground":foreground,"activityEnabled":include_activity,"idleSeconds":idle_seconds,"fullscreen":fullscreen,
            "notificationsAllowed":if notification_known {Some(notification == QUNS_ACCEPTS_NOTIFICATIONS)} else {None},
            "quiet":quiet,"notificationState":if notification_known {Some(notification)} else {None},"microphoneInUse":microphone["inUse"],"microphoneActivity":microphone,
            "power":power,"screens":{"count":GetSystemMetrics(SM_CMONITORS),"primaryWidth":GetSystemMetrics(SM_CXSCREEN),"primaryHeight":GetSystemMetrics(SM_CYSCREEN)},
            "sleepState":if display["suspended"] == true {"suspended"} else {"awake"},"displaySleepState":display["displayState"],"sessionLocked":display["sessionLocked"],"displayMonitor":display,"outboundSharing":false})
    }
}

#[cfg(not(windows))]
pub fn system_snapshot(_include_activity: bool) -> Value {
    json!({"platform":std::env::consts::OS,"available":false,"outboundSharing":false})
}

#[cfg(windows)]
pub fn claim_instance() -> Result<(), String> {
    use windows_sys::Win32::Foundation::{CloseHandle, GetLastError, ERROR_ALREADY_EXISTS};
    use windows_sys::Win32::System::Threading::CreateMutexW;
    let mut instance = INSTANCE
        .lock()
        .map_err(|_| "Instance lock is unavailable")?;
    if instance.is_some() {
        return Ok(());
    }
    let name: Vec<u16> = "Local\\com.qimake.MikuDesktop"
        .encode_utf16()
        .chain(Some(0))
        .collect();
    let handle = unsafe { CreateMutexW(std::ptr::null(), 0, name.as_ptr()) };
    if handle.is_null() {
        return Err(format!(
            "Could not create the single-instance mutex: {}",
            std::io::Error::last_os_error()
        ));
    }
    if unsafe { GetLastError() } == ERROR_ALREADY_EXISTS {
        unsafe {
            CloseHandle(handle);
        }
        return Err("Miku Desktop is already running in this Windows session".into());
    }
    *instance = Some(handle as isize);
    Ok(())
}

#[cfg(not(windows))]
pub fn claim_instance() -> Result<(), String> {
    Err("Windows single-instance service is unavailable on this platform".into())
}

#[cfg(windows)]
pub fn release_instance() {
    let mut instance = INSTANCE
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    if let Some(handle) = instance.take() {
        unsafe {
            windows_sys::Win32::Foundation::CloseHandle(handle as _);
        }
    }
}

#[cfg(not(windows))]
pub fn release_instance() {}
