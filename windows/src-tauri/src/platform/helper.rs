use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Read, Write};
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

const SCRIPT: &str = include_str!("../../../scripts/platform-host.ps1");
const BOOTSTRAP: &str = "$ErrorActionPreference='Stop';[Console]::InputEncoding=[Text.UTF8Encoding]::new($false);[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false);$r=[Console]::In.ReadToEnd()|ConvertFrom-Json;& ([scriptblock]::Create($r.script)) $r.request";
static SPEECH: Mutex<Option<SpeechJob>> = Mutex::new(None);
static NEXT_JOB: AtomicU64 = AtomicU64::new(1);
static CURRENT_JOB: AtomicU64 = AtomicU64::new(0);
static LISTEN_ACTIVE: AtomicBool = AtomicBool::new(false);
static LISTEN_CANCEL: AtomicBool = AtomicBool::new(false);
static LISTEN_PID: AtomicU32 = AtomicU32::new(0);

struct SpeechJob {
    id: u64,
    child: Child,
    progress: Arc<Mutex<Value>>,
}

#[cfg(windows)]
fn bind_to_app_lifetime(child: &Child) -> Result<(), String> {
    use std::os::windows::io::AsRawHandle;
    use windows_sys::Win32::Foundation::CloseHandle;
    use windows_sys::Win32::System::JobObjects::*;
    static JOB: Mutex<Option<isize>> = Mutex::new(None);
    let mut job = JOB
        .lock()
        .map_err(|_| "Platform process lifetime guard is unavailable")?;
    if job.is_none() {
        let handle = unsafe { CreateJobObjectW(std::ptr::null(), std::ptr::null()) };
        if handle.is_null() {
            return Err("Could not create the platform process lifetime guard".into());
        }
        let mut limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = unsafe { std::mem::zeroed() };
        // Browser/file-manager launches may outlive the helper, but microphone and speech helpers may not outlive the app.
        limits.BasicLimitInformation.LimitFlags =
            JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK;
        if unsafe {
            SetInformationJobObject(
                handle,
                JobObjectExtendedLimitInformation,
                &limits as *const _ as _,
                std::mem::size_of_val(&limits) as u32,
            )
        } == 0
        {
            unsafe {
                CloseHandle(handle);
            }
            return Err("Could not configure the platform process lifetime guard".into());
        }
        *job = Some(handle as isize);
    }
    if unsafe { AssignProcessToJobObject(job.unwrap() as _, child.as_raw_handle() as _) } == 0 {
        return Err("Could not bind the platform helper to the app lifetime".into());
    }
    Ok(())
}

fn encoded_command(text: &str) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let bytes: Vec<u8> = text.encode_utf16().flat_map(u16::to_le_bytes).collect();
    let mut output = String::new();
    for block in bytes.chunks(3) {
        let n = ((block[0] as u32) << 16)
            | ((block.get(1).copied().unwrap_or(0) as u32) << 8)
            | block.get(2).copied().unwrap_or(0) as u32;
        output.push(TABLE[((n >> 18) & 63) as usize] as char);
        output.push(TABLE[((n >> 12) & 63) as usize] as char);
        output.push(if block.len() > 1 {
            TABLE[((n >> 6) & 63) as usize] as char
        } else {
            '='
        });
        output.push(if block.len() > 2 {
            TABLE[(n & 63) as usize] as char
        } else {
            '='
        });
    }
    output
}

fn spawn(name: &str, payload: Value, data_dir: &Path) -> Result<Child, String> {
    if !cfg!(windows) {
        return Err("Windows platform services are unavailable on this platform".into());
    }
    let executable = std::env::var_os("SystemRoot")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| "C:\\Windows".into())
        .join("System32/WindowsPowerShell/v1.0/powershell.exe");
    let mut command = Command::new(executable);
    command
        .args([
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-STA",
            "-EncodedCommand",
            &encoded_command(BOOTSTRAP),
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x08000000);
    }
    let mut child = command
        .spawn()
        .map_err(|_| "Windows PowerShell could not be started".to_string())?;
    #[cfg(windows)]
    if let Err(error) = bind_to_app_lifetime(&child) {
        let _ = child.kill();
        let _ = child.wait();
        return Err(error);
    }
    let request =
        json!({"script":SCRIPT,"request":{"action":name,"payload":payload,"dataDir":data_dir}});
    if let Err(error) = child
        .stdin
        .take()
        .ok_or("Platform helper input is unavailable")
        .and_then(|mut input| {
            serde_json::to_writer(&mut input, &request)
                .map_err(|_| "Could not encode platform request")?;
            input.flush().map_err(|_| "Could not send platform request")
        })
    {
        let _ = child.kill();
        let _ = child.wait();
        return Err(error.into());
    }
    Ok(child)
}

pub fn run(
    name: &str,
    payload: Value,
    data_dir: &Path,
    timeout: Duration,
) -> Result<Value, String> {
    let listening = name == "listen_once";
    if listening
        && LISTEN_ACTIVE
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Relaxed)
            .is_err()
    {
        return Err("A microphone request is already active".into());
    }
    struct ListeningGuard(bool);
    impl Drop for ListeningGuard {
        fn drop(&mut self) {
            if self.0 {
                LISTEN_PID.store(0, Ordering::Release);
                LISTEN_ACTIVE.store(false, Ordering::Release);
            }
        }
    }
    let _guard = ListeningGuard(listening);
    if listening {
        LISTEN_CANCEL.store(false, Ordering::Release);
    }
    let mut child = spawn(name, payload, data_dir)?;
    if listening {
        LISTEN_PID.store(child.id(), Ordering::Release);
    }
    let stdout = child
        .stdout
        .take()
        .ok_or("Platform helper output is unavailable")?;
    let reader = std::thread::spawn(move || {
        let mut bytes = Vec::new();
        stdout
            .take(16 * 1024 * 1024 + 1)
            .read_to_end(&mut bytes)
            .map(|_| bytes)
    });
    let started = Instant::now();
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) => {}
            Err(_) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err("Could not read platform helper status".into());
            }
        }
        if started.elapsed() > timeout || (listening && LISTEN_CANCEL.load(Ordering::Acquire)) {
            let _ = child.kill();
            let _ = child.wait();
            let _ = reader.join();
            return Err(if listening && LISTEN_CANCEL.load(Ordering::Acquire) {
                "Speech recognition was stopped"
            } else {
                "Windows platform request timed out"
            }
            .into());
        }
        std::thread::sleep(Duration::from_millis(20));
    };
    let bytes = reader
        .join()
        .map_err(|_| "Platform output reader failed")?
        .map_err(|_| "Could not read platform output")?;
    if bytes.len() > 16 * 1024 * 1024 {
        return Err("Platform response exceeded its size limit".into());
    }
    let result: Value = serde_json::from_slice(&bytes)
        .map_err(|_| "Windows platform helper returned an invalid response")?;
    if !status.success() || result.get("ok") != Some(&Value::Bool(true)) {
        return Err(result
            .get("error")
            .and_then(Value::as_str)
            .unwrap_or("Windows platform request failed")
            .to_string());
    }
    Ok(result.get("value").cloned().unwrap_or(Value::Null))
}

pub fn stop_listening() -> Value {
    LISTEN_CANCEL.store(true, Ordering::Release);
    json!({"stopped":true,"wasActive":LISTEN_ACTIVE.load(Ordering::Acquire)})
}

#[cfg(windows)]
pub fn listening_process() -> u32 {
    LISTEN_PID.load(Ordering::Acquire)
}

pub fn speak(name: &str, payload: Value, data_dir: &Path) -> Result<Value, String> {
    let mut speech = SPEECH.lock().map_err(|_| "Speech state is unavailable")?;
    stop_locked(&mut speech, None)?;
    let mut child = spawn(name, payload, data_dir)?;
    let stdout = child
        .stdout
        .take()
        .ok_or("Speech helper output is unavailable")?;
    let progress = Arc::new(Mutex::new(json!({"state":"starting","event":Value::Null})));
    let updates = progress.clone();
    std::thread::spawn(move || {
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            if let Ok(message) = serde_json::from_str::<Value>(&line) {
                let update = if message.get("event").and_then(Value::as_str) == Some("voice-start")
                {
                    json!({"state":"speaking","event":"voice-start"})
                } else if message.get("event").and_then(Value::as_str) == Some("voice-end") {
                    json!({"state":"completed","event":"voice-end"})
                } else if message.get("ok") == Some(&Value::Bool(false)) {
                    json!({"state":"failed","event":"voice-end","error":message.get("error")})
                } else {
                    continue;
                };
                if let Ok(mut state) = updates.lock() {
                    if state["state"] != "stopped" {
                        *state = update;
                    }
                }
            }
        }
    });
    let id = NEXT_JOB.fetch_add(1, Ordering::Relaxed);
    *speech = Some(SpeechJob {
        id,
        child,
        progress,
    });
    CURRENT_JOB.store(id, Ordering::Release);
    Ok(json!({"jobId":id,"state":"starting"}))
}

pub fn speech_status() -> Result<Value, String> {
    let mut speech = SPEECH.lock().map_err(|_| "Speech state is unavailable")?;
    let Some(job) = speech.as_mut() else {
        return Ok(json!({"state":"idle","running":false}));
    };
    let exit = job
        .child
        .try_wait()
        .map_err(|_| "Could not inspect speech playback")?;
    let mut progress = job
        .progress
        .lock()
        .map_err(|_| "Speech progress is unavailable")?
        .clone();
    if let Some(status) = exit {
        if status.success() && progress["state"] != "completed" {
            progress = json!({"state":"completed","event":"voice-end"});
        } else if !status.success()
            && progress["state"] != "stopped"
            && progress["state"] != "failed"
        {
            progress = json!({"state":"failed","event":"voice-end","error":"Windows speech playback failed"});
        }
    }
    progress["jobId"] = Value::from(job.id);
    progress["running"] = Value::Bool(exit.is_none());
    Ok(progress)
}

pub fn current_speech_job() -> Option<u64> {
    let id = CURRENT_JOB.load(Ordering::Acquire);
    (id != 0).then_some(id)
}

pub fn stop_speech() -> Result<Value, String> {
    stop_speech_job(None)
}

pub fn stop_speech_job(requested: Option<u64>) -> Result<Value, String> {
    let mut speech = SPEECH.lock().map_err(|_| "Speech state is unavailable")?;
    stop_locked(&mut speech, requested)
}

fn stop_locked(speech: &mut Option<SpeechJob>, requested: Option<u64>) -> Result<Value, String> {
    if requested.is_some() && speech.as_ref().map(|job| job.id) != requested {
        return Ok(json!({"stopped":false,"jobId":requested,"reason":"replaced"}));
    }
    if let Some(job) = speech.as_mut() {
        if job
            .child
            .try_wait()
            .map_err(|_| "Could not inspect speech playback")?
            .is_none()
        {
            job.child
                .kill()
                .map_err(|_| "Windows speech playback could not be stopped")?;
            job.child
                .wait()
                .map_err(|_| "Could not finish stopping Windows speech playback")?;
        }
        *job.progress
            .lock()
            .map_err(|_| "Speech progress is unavailable")? =
            json!({"state":"stopped","event":"voice-end"});
        CURRENT_JOB.store(0, Ordering::Release);
    }
    Ok(json!({"stopped":true,"event":"voice-end"}))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn bootstrap_encoding_is_utf16_base64() {
        assert_eq!(encoded_command("A"), "QQA=");
        assert_eq!(encoded_command("你好"), "YE99WQ==");
    }
}
