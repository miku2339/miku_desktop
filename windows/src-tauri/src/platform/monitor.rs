use serde_json::{json, Value};
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicIsize, AtomicU64, Ordering};
use std::sync::OnceLock;
use windows_sys::Win32::Foundation::{HWND, LPARAM, LRESULT, WPARAM};
use windows_sys::Win32::UI::WindowsAndMessaging::*;

static DISPLAY: AtomicI32 = AtomicI32::new(-1);
static LOCKED: AtomicI32 = AtomicI32::new(-1);
static SUSPENDED: AtomicBool = AtomicBool::new(false);
static READY: AtomicBool = AtomicBool::new(false);
static POWER_HANDLE: AtomicIsize = AtomicIsize::new(0);
static RESUMED_AT: AtomicU64 = AtomicU64::new(0);
const DISPLAY_GUID: windows_sys::core::GUID =
    windows_sys::core::GUID::from_u128(0x2b84c20e_ad23_4ddf_93db_05ffbd7efca5);

unsafe extern "system" fn messages(
    hwnd: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    use windows_sys::Win32::System::Power::{
        UnregisterPowerSettingNotification, POWERBROADCAST_SETTING,
    };
    use windows_sys::Win32::System::RemoteDesktop::WTSUnRegisterSessionNotification;
    match message {
        WM_POWERBROADCAST => {
            match wparam as u32 {
                PBT_APMSUSPEND => {
                    SUSPENDED.store(true, Ordering::Release);
                    super::helper::stop_listening();
                    let _ = super::helper::stop_speech();
                }
                PBT_APMRESUMEAUTOMATIC | PBT_APMRESUMESUSPEND => {
                    SUSPENDED.store(false, Ordering::Release);
                    let now = std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .map(|value| value.as_secs())
                        .unwrap_or(0);
                    RESUMED_AT.store(now, Ordering::Release);
                }
                PBT_POWERSETTINGCHANGE if lparam != 0 => {
                    let setting = lparam as *const POWERBROADCAST_SETTING;
                    let guid = (*setting).PowerSetting;
                    if guid.data1 == DISPLAY_GUID.data1
                        && guid.data2 == DISPLAY_GUID.data2
                        && guid.data3 == DISPLAY_GUID.data3
                        && guid.data4 == DISPLAY_GUID.data4
                        && (*setting).DataLength >= 4
                    {
                        let value =
                            std::ptr::read_unaligned((*setting).Data.as_ptr() as *const u32);
                        if value <= 2 {
                            DISPLAY.store(value as i32, Ordering::Release);
                        }
                    }
                }
                _ => {}
            }
            return 1;
        }
        WM_WTSSESSION_CHANGE => {
            match wparam as u32 {
                WTS_SESSION_LOCK => {
                    LOCKED.store(1, Ordering::Release);
                    super::helper::stop_listening();
                    let _ = super::helper::stop_speech();
                }
                WTS_SESSION_UNLOCK => LOCKED.store(0, Ordering::Release),
                _ => {}
            }
            return 0;
        }
        WM_DESTROY => {
            WTSUnRegisterSessionNotification(hwnd);
            let notification = POWER_HANDLE.swap(0, Ordering::AcqRel);
            if notification != 0 {
                UnregisterPowerSettingNotification(notification as _);
            }
            READY.store(false, Ordering::Release);
            PostQuitMessage(0);
            return 0;
        }
        _ => {}
    }
    DefWindowProcW(hwnd, message, wparam, lparam)
}

pub fn start() {
    static STARTED: OnceLock<()> = OnceLock::new();
    STARTED.get_or_init(|| {
        let _ = std::thread::Builder::new()
            .name("miku-platform-state".into())
            .spawn(|| unsafe {
                use windows_sys::Win32::System::LibraryLoader::GetModuleHandleW;
                use windows_sys::Win32::System::Power::RegisterPowerSettingNotification;
                use windows_sys::Win32::System::RemoteDesktop::{
                    WTSRegisterSessionNotification, NOTIFY_FOR_THIS_SESSION,
                };
                let class: Vec<u16> = "MikuDesktopPlatformState"
                    .encode_utf16()
                    .chain(Some(0))
                    .collect();
                let instance = GetModuleHandleW(std::ptr::null());
                let mut definition: WNDCLASSW = std::mem::zeroed();
                definition.lpfnWndProc = Some(messages);
                definition.hInstance = instance;
                definition.lpszClassName = class.as_ptr();
                if RegisterClassW(&definition) == 0 {
                    return;
                }
                let window = CreateWindowExW(
                    WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW,
                    class.as_ptr(),
                    class.as_ptr(),
                    0,
                    0,
                    0,
                    0,
                    0,
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                    instance,
                    std::ptr::null(),
                );
                if window.is_null() {
                    return;
                }
                let notification = RegisterPowerSettingNotification(
                    window,
                    &DISPLAY_GUID,
                    DEVICE_NOTIFY_WINDOW_HANDLE,
                );
                POWER_HANDLE.store(notification as isize, Ordering::Release);
                WTSRegisterSessionNotification(window, NOTIFY_FOR_THIS_SESSION);
                READY.store(notification != 0, Ordering::Release);
                let mut message: MSG = std::mem::zeroed();
                while GetMessageW(&mut message, std::ptr::null_mut(), 0, 0) > 0 {
                    TranslateMessage(&message);
                    DispatchMessageW(&message);
                }
            });
    });
}

pub fn snapshot() -> Value {
    start();
    let display = DISPLAY.load(Ordering::Acquire);
    let locked = LOCKED.load(Ordering::Acquire);
    let resumed = RESUMED_AT.load(Ordering::Acquire);
    json!({"available":READY.load(Ordering::Acquire),"displayState":match display {0=>Some("off"),1=>Some("on"),2=>Some("dimmed"),_=>None},
        "sessionLocked":match locked {0=>Some(false),1=>Some(true),_=>None},"suspended":SUSPENDED.load(Ordering::Acquire),"lastResumeUnix":if resumed > 0 {Some(resumed)} else {None}})
}
