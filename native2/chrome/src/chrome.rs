//! Chrome process ownership, rewritten: launch, profile lock, alive check, reaper.
//!
//! The crate owns what Dart cannot do safely: spawning the browser hidden, refusing a
//! `--user-data-dir` another instance holds (Windows error 32 on its `lockfile`), asking
//! the OS whether a pid is alive, and killing the whole tree on free. CDP itself lives
//! in [`crate::cdp`]. Tree kill shells to `taskkill /T /F` on Windows (the same call the
//! engine's `tk_process_kill_tree` makes); a Job-Object assignment at spawn is the
//! recorded follow-up, not this phase.

use std::io::Read;
use std::io::Write;
use std::process::{Child, Command};
use std::time::{Duration, Instant};

use crate::{guard, live, text, Handle, Msg};

/// A launched or attached browser: the child when we spawned it (reaped on free),
/// the DevTools HTTP endpoint, and the temp profile we delete on free when owned.
pub struct Browser {
    child: Option<Child>,
    pid: u32,
    endpoint: String,
    profile: Option<OwnedProfile>,
}

struct OwnedProfile {
    dir: String,
    owned: bool,
}

/// The DevTools HTTP endpoint behind a browser handle, for the CDP layer.
pub(crate) fn endpoint_of(handle: Handle) -> Result<String, String> {
    // SAFETY: the caller holds the handle; null is the only wrong state.
    Ok(unsafe { live::<Browser>(handle)?.endpoint.clone() })
}

/// Launches `exe` headless (unless `headless` is 0) with `profile` as its
/// `--user-data-dir`, waits for the DevTools endpoint, and answers the browser
/// handle with the debugging port in `out_port`. A profile another Chrome holds
/// is refused before anything spawns.
#[no_mangle]
pub unsafe extern "C" fn tk_cdp_launch(
    exe: *const u8,
    exelen: usize,
    headless: u8,
    profile: *const u8,
    profilelen: usize,
    owned_profile: u8,
    extra: *const u8,
    extralen: usize,
    out_port: *mut u16,
) -> Handle {
    match launch(
        text(exe, exelen),
        headless != 0,
        text(profile, profilelen),
        owned_profile != 0,
        text(extra, extralen),
    ) {
        Ok((browser, port)) => {
            if !out_port.is_null() {
                *out_port = port;
            }
            Box::into_raw(Box::new(browser)) as Handle
        }
        Err(message) => {
            tk_common::set_error(&message);
            std::ptr::null_mut()
        }
    }
}

/// Attaches to the instance serving `host:port` (no child, no profile).
#[no_mangle]
pub unsafe extern "C" fn tk_cdp_attach(host: *const u8, hostlen: usize, port: u16) -> Handle {
    let endpoint = match text(host, hostlen) {
        Ok(h) => format!("http://{}:{}", h, port),
        Err(message) => {
            tk_common::set_error(&message);
            return std::ptr::null_mut();
        }
    };
    match wait_version(&endpoint, Duration::from_secs(10)) {
        Ok(()) => Box::into_raw(Box::new(Browser { child: None, pid: 0, endpoint, profile: None })) as Handle,
        Err(message) => {
            tk_common::set_error(&message);
            std::ptr::null_mut()
        }
    }
}

/// Whether the browser's pid still names a live process (1) or not (0). An
/// attached handle without a pid reports what the endpoint says.
#[no_mangle]
pub unsafe extern "C" fn tk_cdp_alive(handle: Handle) -> i32 {
    guard(|| {
        let browser = live::<Browser>(handle)?;
        Ok(if browser.pid != 0 { alive_pid(browser.pid) } else { endpoint_up(&browser.endpoint) } as i32)
    })
}

/// Best-effort release for the GC finalizer: kills, reaps, deletes, never
/// fails and never reports. `close()` detaches the finalizer first, so this
/// only runs for browsers the caller forgot.
#[no_mangle]
pub unsafe extern "C" fn tk_cdp_release(handle: Handle) {
    if handle.is_null() {
        return;
    }
    let mut owned = Box::from_raw(handle as *mut Browser);
    if owned.pid != 0 {
        kill_tree(owned.pid);
    }
    if let Some(mut child) = owned.child.take() {
        let _ = child.wait_timeout(Duration::from_secs(5));
    }
    if let Some(profile) = owned.profile.take() {
        if profile.owned {
            let _ = delete_dir_retry(&profile.dir);
        }
    }
}

/// Kills the tree, reaps the child, and deletes the owned temp profile (with
/// backoff, so a just-reaped Chrome lets go of it). Best effort per step; the
/// first failure is what `tk_last_error` holds.
#[no_mangle]
pub unsafe extern "C" fn tk_cdp_free(handle: Handle) -> i32 {
    guard(|| {
        let browser = live::<Browser>(handle)?;
        // Take it out of the handle first: a second free is a null handle, not a double kill.
        let owned = unsafe { Box::from_raw(browser as *mut Browser) };
        if owned.pid != 0 {
            kill_tree(owned.pid);
        }
        if let Some(mut child) = owned.child {
            let _ = child.wait_timeout(Duration::from_secs(5));
        }
        if let Some(profile) = owned.profile {
            if profile.owned {
                delete_dir_retry(&profile.dir)?;
            }
        }
        Ok(0)
    })
}

fn launch(exe: Result<&str, String>, headless: bool, profile: Result<&str, String>, owned: bool, extra: Result<&str, String>) -> Result<(Browser, u16), String> {
    let exe = exe?;
    let profile = profile?.to_string();
    let extra = extra?;
    refuse_held_profile(&profile)?;
    let mut cmd = Command::new(exe);
    if headless {
        cmd.arg("--headless=new");
    }
    cmd.args(["--disable-gpu", "--no-first-run", "--no-default-browser-check", "--remote-debugging-port=0"]);
    cmd.arg(format!("--user-data-dir={}", profile));
    for arg in extra.split('\0') {
        if !arg.is_empty() {
            cmd.arg(arg);
        }
    }
    cmd.arg("about:blank");
    cmd.stdin(std::process::Stdio::null()).stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        // No console window flash for the browser we spawned.
        cmd.creation_flags(0x08000000);
    }
    let child = cmd.spawn().msg()?;
    let pid = child.id();
    let (endpoint, port) = wait_endpoint(&profile, Duration::from_secs(15)).map_err(|message| {
        kill_tree(pid);
        message
    })?;
    Ok((Browser { child: Some(child), pid, endpoint, profile: Some(OwnedProfile { dir: profile, owned }) }, port))
}

/// Refuses a `--user-data-dir` another Chrome holds: its `lockfile` cannot be
/// opened for writing then (Windows error 32). A missing lockfile is a fresh
/// profile, not an error; off Windows the check is skipped.
fn refuse_held_profile(profile: &str) -> Result<(), String> {
    let lock = std::path::Path::new(profile).join("lockfile");
    match std::fs::OpenOptions::new().read(true).write(true).open(&lock) {
        Ok(_) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => {
            #[cfg(windows)]
            {
                Err(format!("profile in use ({}): {}", lock.display(), e))
            }
            #[cfg(not(windows))]
            {
                let _ = e;
                Ok(())
            }
        }
    }
}

/// The DevTools endpoint: the port Chrome writes to `<profile>/DevToolsActivePort`
/// on start, proved by a 200 from `/json/version`. The file is re-read every turn:
/// a first read can catch it half-written (or stale from a reused profile), and a
/// port that never serves is a launch failure, not a 10 s wait on a dead port.
fn wait_endpoint(profile: &str, timeout: Duration) -> Result<(String, u16), String> {
    let file = std::path::Path::new(profile).join("DevToolsActivePort");
    let start = Instant::now();
    while start.elapsed() < timeout {
        if let Ok(text) = std::fs::read_to_string(&file) {
            if let Some(first) = text.lines().next() {
                if let Ok(port) = first.trim().parse::<u16>() {
                    let endpoint = format!("http://127.0.0.1:{}", port);
                    if let Ok((200, _)) = http("GET", &endpoint, "/json/version") {
                        return Ok((endpoint, port));
                    }
                }
            }
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    Err("Chrome DevTools endpoint did not become ready".to_string())
}

/// `GET /json/version` until it answers 200: the endpoint is up.
fn wait_version(endpoint: &str, timeout: Duration) -> Result<(), String> {
    let start = Instant::now();
    while start.elapsed() < timeout {
        match http("GET", endpoint, "/json/version") {
            Ok((200, _)) => return Ok(()),
            _ => std::thread::sleep(Duration::from_millis(100)),
        }
    }
    Err("Chrome DevTools endpoint did not become ready".to_string())
}

fn endpoint_up(endpoint: &str) -> bool {
    matches!(http("GET", endpoint, "/json/version"), Ok((200, _)))
}

/// A minimal HTTP/1.1 client over `TcpStream`: the DevTools endpoints only ever
/// need GET and PUT with small bodies, so no HTTP crate is worth it. Reads the
/// header, then exactly `Content-Length` body bytes: the DevTools server keeps
/// the socket open (even past `Connection: close`), so reading to end would
/// hang; and it answers HTTP/1.0 with an empty close, so 1.1 it is.
pub(crate) fn http(method: &str, endpoint: &str, path: &str) -> Result<(u16, Vec<u8>), String> {
    let host = endpoint.strip_prefix("http://").unwrap_or(endpoint);
    let mut stream = std::net::TcpStream::connect(host).msg()?;
    stream.set_read_timeout(Some(Duration::from_secs(10))).msg()?;
    stream.set_write_timeout(Some(Duration::from_secs(10))).msg()?;
    write!(stream, "{} {} HTTP/1.1\r\nHost: {}\r\nConnection: close\r\n\r\n", method, path, host).msg()?;
    let mut raw = Vec::new();
    let mut chunk = [0u8; 4096];
    let head = loop {
        let n = stream.read(&mut chunk).msg()?;
        if n == 0 {
            return Err("bad HTTP response".to_string());
        }
        raw.extend_from_slice(&chunk[..n]);
        if raw.len() > 65536 {
            return Err("bad HTTP response".to_string());
        }
        if let Some(at) = raw.windows(4).position(|w| w == b"\r\n\r\n") {
            break at;
        }
    };
    let status = std::str::from_utf8(&raw[..head]).map_err(|_| "bad HTTP response".to_string())?;
    let code = status.split_whitespace().nth(1).and_then(|s| s.parse::<u16>().ok()).ok_or("bad HTTP status".to_string())?;
    let length = status
        .lines()
        .find_map(|line| {
            let (name, value) = line.split_once(':')?;
            if name.trim().eq_ignore_ascii_case("content-length") {
                value.trim().parse::<usize>().ok()
            } else {
                None
            }
        })
        .unwrap_or(0);
    let mut body = raw[head + 4..].to_vec();
    while body.len() < length {
        let n = stream.read(&mut chunk).msg()?;
        if n == 0 {
            return Err("bad HTTP response".to_string());
        }
        body.extend_from_slice(&chunk[..n]);
    }
    body.truncate(length);
    Ok((code, body))
}

/// The process tree rooted at `pid` killed, children first found. Never fails:
/// a pid already gone is the normal outcome of a kill racing an exit.
fn kill_tree(pid: u32) {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        let _ = Command::new("taskkill").args(["/T", "/F", "/PID", &pid.to_string()]).creation_flags(0x08000000).output();
    }
    #[cfg(not(windows))]
    {
        // SAFETY: signal to a pid we spawned; ESRCH means already gone.
        unsafe {
            libc::kill(pid as i32, libc::SIGTERM);
        }
        let start = Instant::now();
        while start.elapsed() < Duration::from_secs(2) {
            // SAFETY: as above; a zero signal only asks.
            if unsafe { libc::kill(pid as i32, 0) } != 0 {
                return;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        // SAFETY: as above.
        unsafe {
            libc::kill(pid as i32, libc::SIGKILL);
        }
    }
}

fn alive_pid(pid: u32) -> bool {
    #[cfg(windows)]
    {
        // OpenProcess + GetExitCodeProcess: no kill race, no window.
        unsafe {
            let handle = OpenProcess(0x1000, 0, pid);
            if handle.is_null() {
                return false;
            }
            let mut code: u32 = 0;
            let ok = GetExitCodeProcess(handle, &mut code);
            CloseHandle(handle);
            ok != 0 && code == 259
        }
    }
    #[cfg(not(windows))]
    {
        // SAFETY: a zero signal only asks; ESRCH means gone.
        unsafe { libc::kill(pid as i32, 0) == 0 }
    }
}

#[cfg(windows)]
type Dword = u32;
#[cfg(windows)]
type WinHandle = *mut std::ffi::c_void;

#[cfg(windows)]
#[link(name = "kernel32")]
unsafe extern "system" {
    unsafe fn OpenProcess(desired: Dword, inherit: i32, pid: Dword) -> WinHandle;
    unsafe fn GetExitCodeProcess(handle: WinHandle, code: *mut Dword) -> i32;
    unsafe fn CloseHandle(handle: WinHandle) -> i32;
}

/// A just-reaped Chrome still holds files briefly: retry with backoff before
/// giving up, so `close()` leaves no temp profile behind.
fn delete_dir_retry(dir: &str) -> Result<(), String> {
    let mut wait = Duration::from_millis(50);
    for attempt in 0..10 {
        match std::fs::remove_dir_all(dir) {
            Ok(()) => return Ok(()),
            Err(e) if attempt < 9 => {
                let _ = e;
                std::thread::sleep(wait);
                wait = (wait * 2).min(Duration::from_millis(500));
            }
            Err(e) => return Err(format!("cannot delete temp profile {}: {}", dir, e)),
        }
    }
    Ok(())
}

/// `Child::wait` with a timeout: reap when it exits soon, give up (the tree
/// kill already ran) when it does not.
trait WaitTimeout {
    fn wait_timeout(&mut self, timeout: Duration) -> std::io::Result<Option<std::process::ExitStatus>>;
}

impl WaitTimeout for Child {
    fn wait_timeout(&mut self, timeout: Duration) -> std::io::Result<Option<std::process::ExitStatus>> {
        let start = Instant::now();
        loop {
            match self.try_wait()? {
                Some(status) => return Ok(Some(status)),
                None if start.elapsed() >= timeout => return Ok(None),
                None => std::thread::sleep(Duration::from_millis(50)),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn held_profile_probe_treats_missing_lockfile_as_fresh() {
        let dir = std::env::temp_dir().join("tk_chrome_lock_probe");
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        assert!(refuse_held_profile(dir.to_str().unwrap()).is_ok());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn killing_a_gone_pid_is_quiet() {
        kill_tree(u32::MAX);
        assert!(!alive_pid(u32::MAX));
    }
}
