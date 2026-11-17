use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::fs::OpenOptions;
use std::os::windows::fs::OpenOptionsExt;
use std::os::windows::io::AsRawHandle;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use windows_sys::Win32::Foundation::{
    GetLastError, ERROR_IO_PENDING, ERROR_MORE_DATA, HANDLE, WAIT_OBJECT_0, WAIT_TIMEOUT,
};
use windows_sys::Win32::Storage::FileSystem::{ReadFile, WriteFile, FILE_FLAG_OVERLAPPED};
use windows_sys::Win32::System::Threading::{CreateEventW, ResetEvent, WaitForSingleObject};
use windows_sys::Win32::System::IO::{CancelIoEx, GetOverlappedResult, OVERLAPPED};

pub const DEFAULT_PIPE_NAME: &str = r"\\.\pipe\AmdMobilePower.RustGui.Worker.v1";

fn retry_busy_connection<T>(
    timeout: Duration,
    mut connect: impl FnMut() -> std::io::Result<T>,
) -> std::io::Result<T> {
    let deadline = Instant::now() + timeout;
    loop {
        match connect() {
            Ok(stream) => return Ok(stream),
            Err(error) if error.raw_os_error() == Some(231) && Instant::now() < deadline => {
                std::thread::sleep(
                    Duration::from_millis(20)
                        .min(deadline.saturating_duration_since(Instant::now())),
                );
            }
            Err(error) => return Err(error),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PowerLimitTarget {
    pub stapm_watts: i32,
    pub fast_watts: i32,
    pub slow_watts: i32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PowerLineState {
    Unknown,
    Ac,
    Battery,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PowerPolicySettings {
    pub enabled: bool,
    #[serde(default = "default_true")]
    pub battery_enabled: bool,
    #[serde(default = "default_true")]
    pub ac_enabled: bool,
    pub battery_target: PowerLimitTarget,
    pub ac_target: PowerLimitTarget,
}

fn default_true() -> bool {
    true
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PowerPolicyState {
    pub settings: Option<PowerPolicySettings>,
    pub last_observed_power_line: Option<PowerLineState>,
    #[serde(default)]
    pub last_attempt_power_line: Option<PowerLineState>,
    #[serde(default)]
    pub last_applied_power_line: Option<PowerLineState>,
    pub last_applied_target: Option<PowerLimitTarget>,
    pub last_attempt_at: Option<String>,
    pub last_attempt_succeeded: Option<bool>,
    pub last_error: Option<String>,
}

impl PowerLimitTarget {
    pub fn uniform(watts: i32) -> Self {
        Self {
            stapm_watts: watts,
            fast_watts: watts,
            slow_watts: watts,
        }
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ApplyTargetResult {
    pub is_successful: bool,
    pub error: Option<String>,
    pub has_firmware_clamp: bool,
    pub has_stapm_warning: bool,
    pub restore_attempted: bool,
    pub restored_previous_limits: bool,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HealthPayload {
    pub status: String,
    pub worker_version: String,
    pub process_id: u32,
    pub uptime_seconds: f64,
    pub hardware_initialized: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SnapshotPayload {
    pub platform: PlatformPayload,
    pub telemetry: TelemetryPayload,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlatformPayload {
    pub cpu: CpuPayload,
    pub limits: LimitsPayload,
    pub matched_profile: Option<ProfilePayload>,
    pub is_supported: bool,
    pub unsupported_reason: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProfilePayload {
    pub id: String,
    pub display_name: String,
    pub minimum_watts: i32,
    pub maximum_watts: i32,
    pub default_watts: i32,
    pub is_verified: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CpuPayload {
    pub processor_name: String,
    pub vendor: String,
    pub ryzen_adj_family: Option<i32>,
    pub ryzen_adj_family_name: Option<String>,
    pub smu_bios_version: Option<String>,
    pub pm_table_version: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LimitsPayload {
    pub supports_stapm: bool,
    pub supports_fast: bool,
    pub supports_slow: bool,
    pub supports_any: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TelemetryPayload {
    pub target_watts: Option<f64>,
    pub stapm_value_watts: Option<f64>,
    pub fast_value_watts: Option<f64>,
    pub slow_value_watts: Option<f64>,
    pub stapm_limit_watts: Option<f64>,
    pub fast_limit_watts: Option<f64>,
    pub slow_limit_watts: Option<f64>,
    pub tctl_value_celsius: Option<f64>,
    pub tctl_limit_celsius: Option<f64>,
    pub power_line: String,
    pub updated_at: Option<String>,
    pub has_firmware_clamp: bool,
}

#[derive(Debug, Deserialize)]
struct WorkerError {
    code: String,
    message: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Response {
    protocol_version: u32,
    request_id: String,
    success: bool,
    payload: Option<Value>,
    error: Option<WorkerError>,
}

#[derive(Debug, Clone)]
pub struct WorkerClient {
    pipe_name: String,
    io_timeout: Duration,
}

impl WorkerClient {
    pub fn new(pipe_name: impl Into<String>) -> Self {
        Self {
            pipe_name: normalize_pipe_name(pipe_name.into()),
            io_timeout: Duration::from_secs(5),
        }
    }

    #[cfg(test)]
    fn with_io_timeout(pipe_name: impl Into<String>, io_timeout: Duration) -> Self {
        Self {
            pipe_name: normalize_pipe_name(pipe_name.into()),
            io_timeout,
        }
    }

    pub fn health(&self) -> Result<HealthPayload, String> {
        let payload = self.request("getHealth", Value::Null)?;
        serde_json::from_value(payload).map_err(|error| error.to_string())
    }

    pub fn snapshot(&self) -> Result<SnapshotPayload, String> {
        let payload = self.request("getSnapshot", Value::Null)?;
        serde_json::from_value(payload).map_err(|error| error.to_string())
    }

    pub fn apply_target(&self, target: PowerLimitTarget) -> Result<ApplyTargetResult, String> {
        let payload = serde_json::to_value(serde_json::json!({
            "target": target
        }))
        .map_err(|error| format!("unable to build applyTarget payload: {error}"))?;
        let payload = self.request("applyTarget", payload)?;
        serde_json::from_value(payload).map_err(|error| error.to_string())
    }

    pub fn get_power_policy(&self) -> Result<PowerPolicyState, String> {
        let payload = self.request("getPowerPolicy", Value::Null)?;
        serde_json::from_value(payload).map_err(|error| error.to_string())
    }

    pub fn set_power_policy(
        &self,
        settings: PowerPolicySettings,
    ) -> Result<PowerPolicyState, String> {
        let payload = serde_json::to_value(serde_json::json!({
            "settings": settings
        }))
        .map_err(|error| format!("unable to build setPowerPolicy payload: {error}"))?;
        let payload = self.request("setPowerPolicy", payload)?;
        serde_json::from_value(payload).map_err(|error| error.to_string())
    }

    pub fn shutdown(&self) -> Result<(), String> {
        self.request("shutdown", Value::Null).map(|_| ())
    }

    fn request(&self, command: &str, payload: Value) -> Result<Value, String> {
        let request_id = format!(
            "rust-gui-{}-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|duration| duration.as_millis())
                .unwrap_or(0),
            NEXT_REQUEST_ID.fetch_add(1, Ordering::Relaxed)
        );
        let request = serde_json::json!({
            "protocolVersion": 1,
            "requestId": request_id,
            "command": command,
            "payload": payload
        });

        let stream = retry_busy_connection(Duration::from_secs(2), || {
            OpenOptions::new()
                .read(true)
                .write(true)
                .custom_flags(FILE_FLAG_OVERLAPPED)
                .open(&self.pipe_name)
        })
        .map_err(|error| format!("unable to open {}: {error}", self.pipe_name))?;
        let handle = stream.as_raw_handle() as HANDLE;
        let deadline = Instant::now() + self.io_timeout;
        let mut request_bytes = request.to_string().into_bytes();
        request_bytes.push(b'\n');
        write_all_timeout(handle, &request_bytes, deadline)?;
        let response_line = read_line_timeout(handle, deadline)?;

        let response: Response = serde_json::from_str(&response_line)
            .map_err(|error| format!("unable to parse worker response: {error}"))?;
        if response.protocol_version != 1 {
            return Err(format!(
                "unexpected worker protocol version: {}",
                response.protocol_version
            ));
        }
        if response.request_id != request_id {
            return Err("worker response requestId did not match".to_owned());
        }
        if !response.success {
            return Err(match response.error {
                Some(error) => format!("{}: {}", error.code, error.message),
                None => "worker returned failure without an error".to_owned(),
            });
        }
        response
            .payload
            .ok_or_else(|| "worker returned success without a payload".to_owned())
    }
}

static NEXT_REQUEST_ID: AtomicU64 = AtomicU64::new(1);

fn normalize_pipe_name(value: String) -> String {
    const PREFIX: &str = r"\\.\pipe\";
    if value.starts_with(PREFIX) {
        value
    } else {
        format!("{PREFIX}{value}")
    }
}

struct IoEvent(HANDLE);

impl Drop for IoEvent {
    fn drop(&mut self) {
        if !self.0.is_null() {
            unsafe { windows_sys::Win32::Foundation::CloseHandle(self.0) };
        }
    }
}

fn new_io_event() -> Result<IoEvent, String> {
    let event = unsafe { CreateEventW(std::ptr::null(), 1, 0, std::ptr::null()) };
    if event.is_null() {
        return Err(format!("CreateEventW failed: {}", unsafe {
            GetLastError()
        }));
    }
    Ok(IoEvent(event))
}

fn complete_overlapped(
    handle: HANDLE,
    overlapped: &mut OVERLAPPED,
    event: HANDLE,
    deadline: Instant,
) -> Result<u32, String> {
    let remaining = deadline.saturating_duration_since(Instant::now());
    let milliseconds = remaining.as_millis().min(u32::MAX as u128) as u32;
    let wait = unsafe { WaitForSingleObject(event, milliseconds) };
    if wait != WAIT_OBJECT_0 {
        let timed_out = wait == WAIT_TIMEOUT;
        let wait_error = unsafe { GetLastError() };
        unsafe {
            CancelIoEx(handle, overlapped);
            let mut transferred = 0u32;
            // The OVERLAPPED lives on the caller's stack. Wait for cancellation
            // to complete before returning, otherwise the kernel could still
            // write into a freed stack frame.
            GetOverlappedResult(handle, overlapped, &mut transferred, 1);
        }
        return Err(if timed_out {
            "worker pipe I/O timed out".to_owned()
        } else {
            format!("worker pipe wait failed: {wait_error}")
        });
    }
    let mut transferred = 0u32;
    if unsafe { GetOverlappedResult(handle, overlapped, &mut transferred, 0) } == 0 {
        let error = unsafe { GetLastError() };
        if error == ERROR_MORE_DATA && transferred > 0 {
            return Ok(transferred);
        }
        return Err(format!("worker pipe I/O failed: {error}"));
    }
    Ok(transferred)
}

fn write_all_timeout(handle: HANDLE, bytes: &[u8], deadline: Instant) -> Result<(), String> {
    let event = new_io_event()?;
    let mut offset = 0usize;
    while offset < bytes.len() {
        let mut overlapped: OVERLAPPED = unsafe { std::mem::zeroed() };
        overlapped.hEvent = event.0;
        unsafe { ResetEvent(event.0) };
        let mut written = 0u32;
        let ok = unsafe {
            WriteFile(
                handle,
                bytes[offset..].as_ptr(),
                (bytes.len() - offset).min(u32::MAX as usize) as u32,
                &mut written,
                &mut overlapped,
            )
        };
        if ok == 0 {
            let error = unsafe { GetLastError() };
            if error != ERROR_IO_PENDING {
                return Err(format!("unable to write worker request: {error}"));
            }
            written = complete_overlapped(handle, &mut overlapped, event.0, deadline)?;
        }
        if written == 0 {
            return Err("worker pipe closed during write".to_owned());
        }
        offset += written as usize;
    }
    Ok(())
}

fn read_line_timeout(handle: HANDLE, deadline: Instant) -> Result<String, String> {
    let event = new_io_event()?;
    let mut bytes = Vec::new();
    let mut buffer = [0u8; 4096];
    loop {
        let mut overlapped: OVERLAPPED = unsafe { std::mem::zeroed() };
        overlapped.hEvent = event.0;
        unsafe { ResetEvent(event.0) };
        let mut read = 0u32;
        let ok = unsafe {
            ReadFile(
                handle,
                buffer.as_mut_ptr(),
                buffer.len() as u32,
                &mut read,
                &mut overlapped,
            )
        };
        if ok == 0 {
            let error = unsafe { GetLastError() };
            if error != ERROR_IO_PENDING {
                return Err(format!("unable to read worker response: {error}"));
            }
            read = complete_overlapped(handle, &mut overlapped, event.0, deadline)?;
        }
        if read == 0 {
            return Err("worker closed the pipe without a response".to_owned());
        }
        bytes.extend_from_slice(&buffer[..read as usize]);
        if bytes.len() > 1024 * 1024 {
            return Err("worker response exceeded 1 MiB".to_owned());
        }
        if let Some(newline) = bytes.iter().position(|byte| *byte == b'\n') {
            bytes.truncate(newline);
            return String::from_utf8(bytes)
                .map_err(|error| format!("worker response was not UTF-8: {error}"));
        }
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn real_busy_pipe_connects_after_owner_disconnects() {
        use std::os::windows::io::FromRawHandle;
        use windows_sys::Win32::Foundation::INVALID_HANDLE_VALUE;
        use windows_sys::Win32::Storage::FileSystem::PIPE_ACCESS_DUPLEX;
        use windows_sys::Win32::System::Pipes::{
            ConnectNamedPipe, CreateNamedPipeW, DisconnectNamedPipe,
        };
        let name = format!(r"\\.\pipe\AmdMobilePower.RetryTest.{}", std::process::id());
        let wide: Vec<u16> = name.encode_utf16().chain(Some(0)).collect();
        let handle = unsafe {
            CreateNamedPipeW(
                wide.as_ptr(),
                PIPE_ACCESS_DUPLEX,
                1,
                1,
                1024,
                1024,
                0,
                std::ptr::null(),
            )
        };
        assert_ne!(handle, INVALID_HANDLE_VALUE);
        let server = unsafe { std::fs::File::from_raw_handle(handle) };
        let occupied = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(&name)
            .unwrap();
        assert_eq!(
            std::fs::OpenOptions::new()
                .read(true)
                .write(true)
                .open(&name)
                .unwrap_err()
                .raw_os_error(),
            Some(231)
        );
        let (started, ready) = std::sync::mpsc::channel();
        let retry = std::thread::spawn(move || {
            let mut attempts = 0;
            let result = super::retry_busy_connection(std::time::Duration::from_secs(2), || {
                attempts += 1;
                let result = std::fs::OpenOptions::new()
                    .read(true)
                    .write(true)
                    .open(&name);
                if attempts == 1 {
                    started.send(()).unwrap();
                }
                result
            });
            (result, attempts)
        });
        ready
            .recv_timeout(std::time::Duration::from_secs(1))
            .unwrap();
        unsafe {
            assert_ne!(DisconnectNamedPipe(handle), 0);
        }
        unsafe {
            ConnectNamedPipe(handle, std::ptr::null_mut());
        }
        let (connected, attempts) = retry.join().unwrap();
        assert!(connected.is_ok());
        assert!(attempts >= 2);
        drop(connected);
        drop(occupied);
        drop(server);
    }

    #[test]
    fn busy_connection_retries_until_available() {
        let mut attempts = 0;
        let result = super::retry_busy_connection(std::time::Duration::from_secs(1), || {
            attempts += 1;
            if attempts < 3 {
                Err(std::io::Error::from_raw_os_error(231))
            } else {
                Ok(42)
            }
        });
        assert_eq!(result.unwrap(), 42);
        assert_eq!(attempts, 3);
    }

    #[test]
    fn connection_errors_other_than_busy_are_not_retried() {
        for code in [2, 5, 109] {
            let mut attempts = 0;
            let result: std::io::Result<()> =
                super::retry_busy_connection(std::time::Duration::from_secs(1), || {
                    attempts += 1;
                    Err(std::io::Error::from_raw_os_error(code))
                });
            assert_eq!(result.unwrap_err().raw_os_error(), Some(code));
            assert_eq!(attempts, 1);
        }
    }

    #[test]
    fn persistent_busy_connection_has_a_deadline() {
        let start = std::time::Instant::now();
        let mut attempts = 0;
        let result: std::io::Result<()> =
            super::retry_busy_connection(std::time::Duration::from_millis(40), || {
                attempts += 1;
                Err(std::io::Error::from_raw_os_error(231))
            });
        assert_eq!(result.unwrap_err().raw_os_error(), Some(231));
        assert!(attempts >= 2);
        assert!(start.elapsed() >= std::time::Duration::from_millis(40));
        assert!(start.elapsed() < std::time::Duration::from_secs(2));
    }

    #[test]
    fn unresponsive_worker_times_out() {
        use windows_sys::Win32::Foundation::{CloseHandle, INVALID_HANDLE_VALUE};
        use windows_sys::Win32::Storage::FileSystem::PIPE_ACCESS_DUPLEX;
        use windows_sys::Win32::System::Pipes::{
            ConnectNamedPipe, CreateNamedPipeW, PIPE_READMODE_MESSAGE, PIPE_TYPE_MESSAGE, PIPE_WAIT,
        };
        let name = format!(
            r"\\.\pipe\AmdMobilePower.TimeoutTest.{}",
            std::process::id()
        );
        let wide: Vec<u16> = name.encode_utf16().chain(Some(0)).collect();
        let handle = unsafe {
            CreateNamedPipeW(
                wide.as_ptr(),
                PIPE_ACCESS_DUPLEX,
                PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT,
                1,
                8192,
                8192,
                0,
                std::ptr::null(),
            )
        };
        assert_ne!(handle, INVALID_HANDLE_VALUE);
        let handle_address = handle as usize;
        let server = std::thread::spawn(move || unsafe {
            let handle = handle_address as windows_sys::Win32::Foundation::HANDLE;
            ConnectNamedPipe(handle, std::ptr::null_mut());
            std::thread::sleep(std::time::Duration::from_millis(800));
            CloseHandle(handle);
        });
        let client = WorkerClient::with_io_timeout(&name, std::time::Duration::from_millis(300));
        let start = std::time::Instant::now();
        let error = client.health().unwrap_err();
        assert!(error.contains("timed out"), "{error}");
        assert!(start.elapsed() < std::time::Duration::from_secs(2));
        server.join().unwrap();
    }

    use super::{normalize_pipe_name, PowerLimitTarget, PowerPolicySettings, WorkerClient};

    #[test]
    fn pipe_name_is_normalized_for_the_windows_namespace() {
        assert_eq!(
            WorkerClient::new("AmdMobilePower.Test").pipe_name,
            r"\\.\pipe\AmdMobilePower.Test"
        );
        assert_eq!(
            WorkerClient::new(r"\\.\pipe\AmdMobilePower.Test").pipe_name,
            r"\\.\pipe\AmdMobilePower.Test"
        );
        assert_eq!(
            normalize_pipe_name("AmdMobilePower.Test".to_owned()),
            r"\\.\pipe\AmdMobilePower.Test"
        );
    }

    #[test]
    fn target_payload_uses_the_v1_camel_case_contract() {
        let value = serde_json::to_value(super::PowerLimitTarget::uniform(12)).unwrap();
        assert_eq!(
            value,
            serde_json::json!({
                "stapmWatts": 12,
                "fastWatts": 12,
                "slowWatts": 12
            })
        );
    }

    #[test]
    fn power_policy_payload_uses_the_v1_camel_case_contract() {
        let value = serde_json::to_value(PowerPolicySettings {
            enabled: true,
            battery_enabled: true,
            ac_enabled: false,
            battery_target: PowerLimitTarget::uniform(12),
            ac_target: PowerLimitTarget::uniform(45),
        })
        .unwrap();
        assert_eq!(
            value,
            serde_json::json!({
                "enabled": true,
                "batteryEnabled": true,
                "acEnabled": false,
                "batteryTarget": {
                    "stapmWatts": 12,
                    "fastWatts": 12,
                    "slowWatts": 12
                },
                "acTarget": {
                    "stapmWatts": 45,
                    "fastWatts": 45,
                    "slowWatts": 45
                }
            })
        );
    }

    #[test]
    fn legacy_power_policy_defaults_both_power_lines_to_enabled() {
        let settings: PowerPolicySettings = serde_json::from_value(serde_json::json!({
            "enabled": true,
            "batteryTarget": {
                "stapmWatts": 10,
                "fastWatts": 10,
                "slowWatts": 10
            },
            "acTarget": {
                "stapmWatts": 45,
                "fastWatts": 45,
                "slowWatts": 45
            }
        }))
        .unwrap();

        assert!(settings.battery_enabled);
        assert!(settings.ac_enabled);
    }

    #[test]
    fn legacy_power_policy_state_defaults_attempt_and_applied_lines() {
        let state: super::PowerPolicyState = serde_json::from_value(serde_json::json!({
            "settings": null,
            "lastObservedPowerLine": "battery",
            "lastAppliedTarget": {
                "stapmWatts": 10,
                "fastWatts": 10,
                "slowWatts": 10
            },
            "lastAttemptAt": "2026-11-18T00:00:00Z",
            "lastAttemptSucceeded": true,
            "lastError": null
        }))
        .unwrap();

        assert_eq!(
            state.last_observed_power_line,
            Some(super::PowerLineState::Battery)
        );
        assert!(state.last_attempt_power_line.is_none());
        assert!(state.last_applied_power_line.is_none());
    }
}
