//! Capture-session activity only; no audio client or capture buffer is opened.

use serde_json::{json, Value};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};
use windows::core::Interface;
use windows::Win32::Media::Audio::{
    eCapture, AudioSessionStateActive, IAudioSessionControl2, IAudioSessionManager2,
    IMMDeviceEnumerator, MMDeviceEnumerator, DEVICE_STATE_ACTIVE,
};
use windows::Win32::System::Com::{
    CoCreateInstance, CoInitializeEx, CoUninitialize, CLSCTX_ALL, COINIT_MULTITHREADED,
};

type Sample = Arc<Mutex<(Instant, Value)>>;

unsafe fn microphone_active() -> windows::core::Result<bool> {
    let enumerator: IMMDeviceEnumerator = CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL)?;
    let devices = enumerator.EnumAudioEndpoints(eCapture, DEVICE_STATE_ACTIVE)?;
    let own_pid = std::process::id();
    let listening_pid = super::helper::listening_process();
    for index in 0..devices.GetCount()? {
        let device = devices.Item(index)?;
        let manager: IAudioSessionManager2 = device.Activate(CLSCTX_ALL, None)?;
        let sessions = manager.GetSessionEnumerator()?;
        for index in 0..sessions.GetCount()? {
            let session = sessions.GetSession(index)?;
            if session.GetState()? != AudioSessionStateActive {
                continue;
            }
            let session: IAudioSessionControl2 = session.cast()?;
            let pid = session.GetProcessId()?;
            if pid != own_pid && pid != listening_pid {
                return Ok(true);
            }
        }
    }
    Ok(false)
}

fn samples() -> &'static Sample {
    static SAMPLE: OnceLock<Sample> = OnceLock::new();
    SAMPLE.get_or_init(|| {
        let sample = Arc::new(Mutex::new((Instant::now(), json!({"available":false,"inUse":null}))));
        let output = sample.clone();
        std::thread::spawn(move || unsafe {
            let initialized = CoInitializeEx(None, COINIT_MULTITHREADED);
            if initialized.is_err() {
                return;
            }
            struct Apartment;
            impl Drop for Apartment {
                fn drop(&mut self) {
                    unsafe { CoUninitialize(); }
                }
            }
            let _apartment = Apartment;
            loop {
                let value = match microphone_active() {
                    Ok(active) => json!({"available":true,"inUse":active}),
                    Err(error) => json!({"available":false,"inUse":null,"error":format!("Core Audio query failed ({:#X})",error.code().0)}),
                };
                if let Ok(mut sample) = output.lock() {
                    *sample = (Instant::now(), value);
                }
                std::thread::sleep(Duration::from_secs(2));
            }
        });
        sample
    })
}

pub fn snapshot() -> Value {
    let Ok(sample) = samples().lock() else {
        return json!({"available":false,"inUse":null});
    };
    let mut value = sample.1.clone();
    if sample.0.elapsed() > Duration::from_secs(10) {
        value["available"] = json!(false);
        value["inUse"] = Value::Null;
    }
    value["scope"] = json!("wasapi-capture-sessions");
    value["audioRead"] = json!(false);
    value
}
