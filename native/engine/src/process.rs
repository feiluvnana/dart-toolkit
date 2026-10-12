//! Process-tree termination, rewritten: `tk_process_kill_tree`.
//!
//! A cancel, timeout or signal must leave no orphan: the child and everything under it
//! dies, children first. Windows kills through the process tree (`taskkill /T /F`);
//! Unix stops the target so nothing new spawns meanwhile, reaps depth-first, then kills.

use crate::guard;

/// Kills the process `pid` and everything under it, children first. Never fails for
/// processes already gone: stopping early is the normal outcome of a kill racing an exit.
#[no_mangle]
pub extern "C" fn tk_process_kill_tree(pid: u32) -> i32 {
    guard(|| {
        kill_tree(pid)?;
        Ok(0)
    })
}

fn kill_tree(pid: u32) -> Result<(), String> {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        if pid == 0 || pid == std::process::id() {
            return Err(format!("refused to kill pid {}", pid));
        }
        // No console window flash: the kill runs hidden.
        let status = std::process::Command::new("taskkill")
            .args(["/T", "/F", "/PID", &pid.to_string()])
            .creation_flags(0x08000000)
            .output()
            .map_err(|e| e.to_string())?;
        // taskkill reports failure when the pid is already gone; that is not an error here.
        let _ = status;
        Ok(())
    }
    #[cfg(not(windows))]
    {
        kill_tree_unix(pid)
    }
}

/// `pid` as a signal target, or `None` when `kill()` would read it as more than one process or
/// as one we must never touch: `0` is the caller's process group, any `u32` above `i32::MAX`
/// casts negative (`-1` signals EVERY process the user owns, another negative a whole group),
/// `1` is launchd/init, and the caller itself is never part of a tree it kills.
#[cfg(not(windows))]
pub(crate) fn signalable(pid: u32) -> Option<i32> {
    let p = i32::try_from(pid).ok()?;
    if p <= 1 || pid == std::process::id() {
        return None;
    }
    Some(p)
}

#[cfg(not(windows))]
fn kill_tree_unix(pid: u32) -> Result<(), String> {
    // Never a group, never everyone, never launchd or ourselves: see [`signalable`].
    let Some(pid) = signalable(pid) else {
        return Err(format!("refused to signal pid {}: not a single other process", pid));
    };
    // Stop it first: nothing under it starts meanwhile.
    // SAFETY: kill with a signal number is async-signal-safe; ESRCH means already gone.
    let stopped = unsafe { libc::kill(pid, libc::SIGSTOP) } == 0;
    if !stopped {
        return Ok(());
    }
    for child in children_of(pid) {
        // A child the guard refuses (it can't be one, but never trust a list) is skipped.
        if signalable(child as u32).is_some() {
            kill_tree_unix(child as u32)?;
        }
    }
    // SAFETY: as above; the process cannot have been reaped without us (we never wait).
    unsafe {
        libc::kill(pid, libc::SIGKILL);
    }
    Ok(())
}

/// Direct children of `pid`: `/proc` on Linux, libproc on macOS, pgrep -P elsewhere.
#[cfg(not(windows))]
fn children_of(pid: i32) -> Vec<i32> {
    #[cfg(target_os = "linux")]
    {
        let mut out = Vec::new();
        if let Ok(dir) = std::fs::read_dir("/proc") {
            for entry in dir.flatten() {
                let name = entry.file_name();
                let name = name.to_string_lossy();
                if name.parse::<i32>().is_err() {
                    continue;
                }
                if let Ok(stat) = std::fs::read_to_string(format!("/proc/{}/stat", name)) {
                    // Comm may hold spaces/parens; ppid follows the last ')'.
                    if let Some(tail) = stat.rsplit_once(')') {
                        let ppid = tail.1.split_whitespace().nth(2).and_then(|s| s.parse::<i32>().ok());
                        if ppid == Some(pid) {
                            if let Ok(id) = name.parse::<i32>() {
                                out.push(id);
                            }
                        }
                    }
                }
            }
        }
        return out;
    }
    #[cfg(target_os = "macos")]
    {
        // libproc, not a `pgrep` child: dart:io reaps every child of the VM, so a
        // Command spawned in-process can lose its own exit status and read nothing.
        let mut buf = vec![0 as libc::pid_t; 4096];
        let bytes = (buf.len() * std::mem::size_of::<libc::pid_t>()) as libc::c_int;
        // SAFETY: the buffer holds `bytes` bytes; the call writes at most that many.
        let n = unsafe { libc::proc_listchildpids(pid, buf.as_mut_ptr().cast(), bytes) };
        if n <= 0 {
            return Vec::new();
        }
        buf.truncate((n as usize).min(buf.len()));
        return buf.into_iter().filter(|&c| c > 0).collect();
    }
    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    {
        let mut out = Vec::new();
        if let Ok(run) = std::process::Command::new("pgrep").args(["-P", &pid.to_string()]).output() {
            for line in String::from_utf8_lossy(&run.stdout).lines() {
                if let Ok(id) = line.trim().parse::<i32>() {
                    out.push(id);
                }
            }
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Never signal a sentinel pid in a test: `u32::MAX as i32` is -1, and `kill(-1, …)`
    /// reaches every process the user owns. The guard is tested as a pure function.
    #[test]
    #[cfg(not(windows))]
    fn group_and_everyone_pids_are_refused() {
        assert_eq!(signalable(u32::MAX), None);
        assert_eq!(signalable(i32::MAX as u32 + 1), None);
        assert_eq!(signalable(0), None);
        assert_eq!(signalable(1), None);
        assert_eq!(signalable(std::process::id()), None);
        assert_eq!(signalable(4242), Some(4242));
    }

    #[test]
    fn kills_a_child_and_its_child() {
        let mut child = std::process::Command::new(if cfg!(windows) { "cmd" } else { "sh" })
            .args(if cfg!(windows) { ["/c", "ping -n 60 127.0.0.1 >NUL"].as_slice() } else { ["-c", "sleep 60"].as_slice() })
            .spawn()
            .expect("spawn test sleeper");
        let pid = child.id();
        assert_eq!(tk_process_kill_tree(pid), 0);
        // Reaped promptly: the tree kill waited for nothing, so allow a grace here.
        for _ in 0..100 {
            match child.try_wait() {
                Ok(Some(_)) => return,
                Ok(None) => std::thread::sleep(std::time::Duration::from_millis(50)),
                Err(_) => return,
            }
        }
        panic!("child {} outlived the tree kill", pid);
    }
}
