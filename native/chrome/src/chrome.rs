//! Chrome process ownership: launch, profile lock, alive check, reaper.
//!
//! The crate owns what Dart cannot do safely: spawning the browser hidden, refusing a
//! `--user-data-dir` another instance holds (Windows error 32 on its `lockfile`), asking
//! the OS whether a pid is alive, and killing the whole tree on free. CDP itself lives
//! in [`crate::cdp`]. Tree kill shells to `taskkill /T /F` on Windows (the same call the
//! engine's `tk_process_kill_tree` makes); assigning a Job Object at spawn would be
//! stronger, and is not done yet.
//!
//! Launch and attach are jobs: the handle is answered at once and the job fills it
//! in. Freeing the handle mid-launch is safe: the job sees `closed` and kills what
//! it spawned.

use std::io::Read;
use std::io::Write;
use std::process::{Child, Command};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use crate::{guard, live, lock, queue, stopped, text, Done, Handle, Msg, Progress, CLOSED};

/// What a browser handle and its in-flight jobs share.
pub(crate) type BrowserRef = Arc<Mutex<Browser>>;

/// A launched or attached browser: the child when we spawned it (reaped on free),
/// the DevTools HTTP endpoint (empty until the launch job finds it), and the temp
/// profile we delete on free when owned. `closed` is set by free and release.
pub(crate) struct Browser {
    child: Option<Child>,
    pid: u32,
    endpoint: String,
    profile: Option<OwnedProfile>,
    pub(crate) closed: bool,
}

struct OwnedProfile {
    dir: String,
    owned: bool,
}

/// The shared state behind a browser handle and its endpoint, for the CDP layer:
/// an error once the browser is closed or before its launch finished.
pub(crate) fn browser_of(handle: Handle) -> Result<(BrowserRef, String), String> {
    // SAFETY: the caller holds the handle; null is the only wrong state.
    let shared = unsafe { live::<BrowserRef>(handle)? }.clone();
    let endpoint = {
        let browser = lock(&shared);
        if browser.closed {
            return Err(CLOSED.to_string());
        }
        if browser.endpoint.is_empty() {
            return Err("Chrome is not running yet".to_string());
        }
        browser.endpoint.clone()
    };
    Ok((shared, endpoint))
}

fn new_handle() -> (BrowserRef, Handle) {
    let shared = Arc::new(Mutex::new(Browser { child: None, pid: 0, endpoint: String::new(), profile: None, closed: false }));
    let handle = Box::into_raw(Box::new(shared.clone())) as Handle;
    (shared, handle)
}

/// Queues a launch of `exe` headless (unless `headless` is 0) with `profile` as
/// its `--user-data-dir` (`extra`: NUL-separated arguments). The browser handle
/// is written to `out_browser` at once; the job waits for the DevTools endpoint
/// and answers it as text (`http://127.0.0.1:<port>`). A profile another Chrome
/// holds is refused before anything spawns. A failed launch kills what it spawned
/// and deletes an owned profile before it reports.
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
    out_browser: *mut Handle,
    done: Done,
    stop: *const u8,
    _progress: Progress,
    _id: i64,
) -> i32 {
    guard(|| {
        let exe = text(exe, exelen)?.to_string();
        let profile = text(profile, profilelen)?.to_string();
        let extra: Vec<String> = text(extra, extralen)?.split('\0').filter(|a| !a.is_empty()).map(String::from).collect();
        if out_browser.is_null() {
            return Err("no slot for the browser handle".to_string());
        }
        let owned = owned_profile != 0;
        let (shared, handle) = new_handle();
        let rc = queue(done, stop, move || {
            let result = launch(&shared, &exe, headless != 0, &profile, owned, &extra);
            if result.is_err() {
                reap(&shared);
                // Chrome may have recreated the folder after a close deleted it.
                if owned {
                    let _ = delete_dir_retry(&profile);
                }
            }
            result
        });
        if rc == 0 {
            *out_browser = handle;
        } else {
            drop(Box::from_raw(handle as *mut BrowserRef));
        }
        Ok(rc)
    })
}

/// Queues an attach to the instance serving `host:port` (no child, no profile):
/// the handle is written to `out_browser` at once, and the job answers the
/// endpoint once `/json/version` serves (10 s at most).
#[no_mangle]
pub unsafe extern "C" fn tk_cdp_attach(
    host: *const u8,
    hostlen: usize,
    port: u16,
    out_browser: *mut Handle,
    done: Done,
    stop: *const u8,
    _progress: Progress,
    _id: i64,
) -> i32 {
    guard(|| {
        let endpoint = format!("http://{}:{}", text(host, hostlen)?, port);
        if out_browser.is_null() {
            return Err("no slot for the browser handle".to_string());
        }
        let (shared, handle) = new_handle();
        let rc = queue(done, stop, move || {
            wait_version(&endpoint, Duration::from_secs(10))?;
            let mut browser = lock(&shared);
            if browser.closed {
                return Err(CLOSED.to_string());
            }
            browser.endpoint = endpoint.clone();
            Ok(endpoint.into_bytes())
        });
        if rc == 0 {
            *out_browser = handle;
        } else {
            drop(Box::from_raw(handle as *mut BrowserRef));
        }
        Ok(rc)
    })
}

/// Whether the browser's pid still names a live process (1) or not (0). An
/// attached handle without a pid reports what the endpoint says.
#[no_mangle]
pub unsafe extern "C" fn tk_cdp_alive(handle: Handle) -> i32 {
    guard(|| {
        let shared = live::<BrowserRef>(handle)?;
        let (pid, endpoint) = {
            let browser = lock(shared);
            if browser.closed {
                return Ok(0);
            }
            (browser.pid, browser.endpoint.clone())
        };
        Ok(if pid != 0 { alive_pid(pid) } else { !endpoint.is_empty() && endpoint_up(&endpoint) } as i32)
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
    let shared = Box::from_raw(handle as *mut BrowserRef);
    lock(&shared).closed = true;
    if let Some(profile) = reap(&shared) {
        if profile.owned {
            let _ = delete_dir_retry(&profile.dir);
        }
    }
}

/// Kills the tree, reaps the child, and deletes the owned temp profile (with
/// backoff, so a just-reaped Chrome lets go of it); a launch still in flight
/// sees `closed` and stops. Best effort per step; the first failure is what
/// `tk_last_error` holds.
#[no_mangle]
pub unsafe extern "C" fn tk_cdp_free(handle: Handle) -> i32 {
    guard(|| {
        live::<BrowserRef>(handle)?;
        // Take it out of the handle first: a second free is a null handle, not a double kill.
        let shared = unsafe { Box::from_raw(handle as *mut BrowserRef) };
        lock(&shared).closed = true;
        if let Some(profile) = reap(&shared) {
            if profile.owned {
                delete_dir_retry(&profile.dir)?;
            }
        }
        Ok(0)
    })
}

/// Kills and reaps whatever `shared` spawned, answering the profile it held.
fn reap(shared: &BrowserRef) -> Option<OwnedProfile> {
    let (pid, child, profile) = {
        let mut browser = lock(shared);
        (std::mem::take(&mut browser.pid), browser.child.take(), browser.profile.take())
    };
    if pid != 0 {
        kill_tree(pid);
    }
    if let Some(mut child) = child {
        let _ = child.wait_timeout(Duration::from_secs(5));
    }
    profile
}

fn launch(shared: &BrowserRef, exe: &str, headless: bool, profile: &str, owned: bool, extra: &[String]) -> Result<Vec<u8>, String> {
    stopped()?;
    refuse_held_profile(profile)?;
    let mut cmd = Command::new(exe);
    if headless {
        cmd.arg("--headless=new");
    }
    cmd.args(["--disable-gpu", "--no-first-run", "--no-default-browser-check", "--remote-debugging-port=0"]);
    // `navigator.webdriver` is set before any page script runs: only this flag clears it.
    // The user agent comes from the caller (`--user-agent=` in `extra`); the rest of the
    // marks automation leaves are hidden per navigation (cdp.rs `stealth`).
    cmd.args(["--disable-blink-features=AutomationControlled", "--hide-scrollbars", "--mute-audio"]);
    cmd.arg(format!("--user-data-dir={}", profile));
    cmd.args(extra);
    cmd.arg("about:blank");
    cmd.stdin(std::process::Stdio::null()).stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        // No console window flash for the browser we spawned.
        cmd.creation_flags(0x08000000);
    }
    let child = cmd.spawn().map_err(|e| format!("{}: {}", exe, e))?;
    {
        let mut browser = lock(shared);
        browser.pid = child.id();
        browser.child = Some(child);
        browser.profile = Some(OwnedProfile { dir: profile.to_string(), owned });
        if browser.closed {
            return Err(CLOSED.to_string());
        }
    }
    let endpoint = wait_endpoint(profile, Duration::from_secs(15))?;
    let mut browser = lock(shared);
    if browser.closed {
        return Err(CLOSED.to_string());
    }
    browser.endpoint = endpoint.clone();
    Ok(endpoint.into_bytes())
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
/// Stops when the caller sets the stop byte.
fn wait_endpoint(profile: &str, timeout: Duration) -> Result<String, String> {
    let file = std::path::Path::new(profile).join("DevToolsActivePort");
    let start = Instant::now();
    while start.elapsed() < timeout {
        stopped()?;
        if let Ok(text) = std::fs::read_to_string(&file) {
            if let Some(first) = text.lines().next() {
                if let Ok(port) = first.trim().parse::<u16>() {
                    let endpoint = format!("http://127.0.0.1:{}", port);
                    if let Ok((200, _)) = http("GET", &endpoint, "/json/version") {
                        return Ok(endpoint);
                    }
                }
            }
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    Err("Chrome DevTools endpoint did not become ready".to_string())
}

/// `GET /json/version` until it answers 200: the endpoint is up. Stops when the
/// caller sets the stop byte.
fn wait_version(endpoint: &str, timeout: Duration) -> Result<(), String> {
    let start = Instant::now();
    while start.elapsed() < timeout {
        stopped()?;
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

/// `pid` as a signal target, or `None` when `kill()` would read it as more than one process or
/// as one we must never touch: `0` is the caller's process group, any `u32` above `i32::MAX`
/// casts negative (`-1` signals EVERY process the user owns, another negative a whole group),
/// `1` is launchd/init, and the caller itself is never part of a tree it kills.
pub(crate) fn signalable(pid: u32) -> Option<i32> {
    let p = i32::try_from(pid).ok()?;
    if p <= 1 || pid == std::process::id() {
        return None;
    }
    Some(p)
}

/// The process tree rooted at `pid` killed, children first found. Never fails:
/// a pid already gone is the normal outcome of a kill racing an exit.
fn kill_tree(pid: u32) {
    // Never a group, never everyone, never launchd or ourselves: see [`signalable`].
    let Some(target) = signalable(pid) else {
        return;
    };
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        let _ = Command::new("taskkill").args(["/T", "/F", "/PID", &pid.to_string()]).creation_flags(0x08000000).output();
    }
    #[cfg(not(windows))]
    {
        // SAFETY: signal to a pid we spawned; ESRCH means already gone.
        unsafe {
            libc::kill(target, libc::SIGTERM);
        }
        let start = Instant::now();
        while start.elapsed() < Duration::from_secs(2) {
            // SAFETY: as above; a zero signal only asks.
            if unsafe { libc::kill(target, 0) } != 0 {
                return;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        // SAFETY: as above.
        unsafe {
            libc::kill(target, libc::SIGKILL);
        }
    }
}

fn alive_pid(pid: u32) -> bool {
    if signalable(pid).is_none() {
        return false;
    }
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
        // SAFETY: a zero signal only asks; the guard above refused every special pid.
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
/// giving up, so `close()` leaves no temp profile behind. A missing one is fine.
fn delete_dir_retry(dir: &str) -> Result<(), String> {
    let mut wait = Duration::from_millis(50);
    for attempt in 0..10 {
        match std::fs::remove_dir_all(dir) {
            Ok(()) => return Ok(()),
            // Already gone: a launch that failed and a close can both delete it.
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(()),
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

    /// Never signal a sentinel pid in a test: `u32::MAX as i32` is -1, and `kill(-1, …)`
    /// reaches every process the user owns. The guard is tested as a pure function instead.
    #[test]
    fn group_and_everyone_pids_are_never_signal_targets() {
        assert_eq!(signalable(u32::MAX), None); // -1: every process
        assert_eq!(signalable(i32::MAX as u32 + 1), None); // negative: a process group
        assert_eq!(signalable(0), None); // our own process group
        assert_eq!(signalable(1), None); // launchd / init
        assert_eq!(signalable(std::process::id()), None); // ourselves
        assert_eq!(signalable(4242), Some(4242));
        assert!(!alive_pid(u32::MAX));
    }
}
