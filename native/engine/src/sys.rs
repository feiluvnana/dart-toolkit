//! Filesystem syscalls the toolkit needs without spawning processes, rewritten.
//!
//! `tk_chmod`, `tk_file_id`, `tk_copy_file`, the in-process claim table, and the new
//! `tk_rename` with Windows held-target retries (a target another process holds open).

use crate::{guard, stopped, text, watch};
use std::io::{Read, Write};

/// Sets the permission bits of `path` to `mode`, through a link as chmod(2) does.
/// Windows has one bit of it: without the owner's write bit the file is read-only.
#[no_mangle]
pub unsafe extern "C" fn tk_chmod(path: *const u8, plen: usize, mode: u32) -> i32 {
    guard(|| {
        let path = text(path, plen)?;
        let fail = |e: std::io::Error| e.to_string();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode & 0o7777)).map_err(fail)?;
        }
        #[cfg(not(unix))]
        {
            let mut perms = std::fs::metadata(path).map_err(fail)?.permissions();
            perms.set_readonly(mode & 0o200 == 0);
            std::fs::set_permissions(path, perms).map_err(fail)?;
        }
        Ok(0)
    })
}

/// The identity of the file at `path` as two numbers in `out`: device+inode on Unix,
/// volume serial+file index on Windows. A renamed file keeps it; a replaced one differs.
#[no_mangle]
pub unsafe extern "C" fn tk_file_id(path: *const u8, plen: usize, out: *mut u64) -> i32 {
    guard(|| {
        let path = text(path, plen)?;
        let (a, b) = file_id(path).map_err(|e| e.to_string())?;
        *out = a;
        *out.add(1) = b;
        Ok(0)
    })
}

#[cfg(unix)]
fn file_id(path: &str) -> std::io::Result<(u64, u64)> {
    use std::os::unix::fs::MetadataExt;
    let m = std::fs::metadata(path)?;
    Ok((m.dev(), m.ino()))
}

#[cfg(windows)]
fn file_id(path: &str) -> std::io::Result<(u64, u64)> {
    use std::os::windows::fs::OpenOptionsExt;
    use std::os::windows::io::AsRawHandle;
    #[repr(C)]
    #[derive(Default)]
    struct FileInfo {
        attributes: u32,
        created: [u32; 2],
        accessed: [u32; 2],
        written: [u32; 2],
        volume: u32,
        size_high: u32,
        size_low: u32,
        links: u32,
        index_high: u32,
        index_low: u32,
    }
    #[link(name = "kernel32")]
    extern "system" {
        fn GetFileInformationByHandle(file: *mut std::ffi::c_void, info: *mut FileInfo) -> i32;
    }
    // No access at all: a file another process holds open for writing still answers.
    let f = std::fs::OpenOptions::new().access_mode(0).share_mode(7).open(path)?;
    let mut info = FileInfo::default();
    if unsafe { GetFileInformationByHandle(f.as_raw_handle() as *mut _, &mut info) } == 0 {
        return Err(std::io::Error::last_os_error());
    }
    Ok((info.volume as u64, ((info.index_high as u64) << 32) | info.index_low as u64))
}

/// Renames `src` over `dst`: atomic replace on every platform. On Windows a held target
/// (errors 5/32) waits with backoff and retries — the `tk_rename` semantics — because an
/// antivirus scanner or Explorer may hold the destination briefly.
#[no_mangle]
pub unsafe extern "C" fn tk_rename(src: *const u8, slen: usize, dst: *const u8, dlen: usize) -> i32 {
    guard(|| {
        let (src, dst) = (text(src, slen)?.to_string(), text(dst, dlen)?.to_string());
        #[cfg(windows)]
        {
            let mut wait = std::time::Duration::from_millis(10);
            for attempt in 0.. {
                match std::fs::rename(&src, &dst) {
                    Ok(()) => return Ok(0),
                    Err(e) if matches!(e.raw_os_error(), Some(5) | Some(32)) && attempt < 12 => {
                        std::thread::sleep(wait);
                        wait = (wait * 2).min(std::time::Duration::from_millis(400));
                    }
                    Err(e) => return Err(e.to_string()),
                }
            }
            unreachable!()
        }
        #[cfg(not(windows))]
        {
            std::fs::rename(&src, &dst).map_err(|e| e.to_string())?;
            Ok(0)
        }
    })
}

/// Copies `src` to `dest`, a new file (the caller's temporary, renamed into place after):
/// a clone where the filesystem makes one (APFS), else in chunks, in the kernel where it
/// can (Linux), telling `progress` the bytes so far and stopping once `stop` is set. The
/// copy keeps the source's permission bits. A failed or stopped copy removes `dest`.
#[no_mangle]
pub unsafe extern "C" fn tk_copy_file(
    src: *const u8,
    slen: usize,
    dest: *const u8,
    dlen: usize,
    progress: crate::archive::ProgressCb,
    stop: *const u8,
) -> i32 {
    let _watch = watch(stop);
    guard(|| {
        let (src, dest) = (text(src, slen)?, text(dest, dlen)?);
        let result = copy_file(src, dest, progress);
        if result.is_err() {
            let _ = std::fs::remove_file(dest);
        }
        result
    })
}

fn copy_file(src: &str, dest: &str, progress: crate::archive::ProgressCb) -> Result<i32, String> {
    fn fail(p: &str) -> impl Fn(std::io::Error) -> String + '_ {
        move |e| format!("{}: {}", p, e)
    }
    let tell = |done: u64, total: u64| -> Result<(), String> {
        if let Some(cb) = progress {
            unsafe { cb(0, 1, done, total, std::ptr::null(), 0) };
        }
        stopped()
    };
    let mut from = std::fs::File::open(src).map_err(fail(src))?;
    let meta = from.metadata().map_err(fail(src))?;
    let total = meta.len();
    #[cfg(target_os = "macos")]
    {
        let (s, d) = (std::ffi::CString::new(src).map_err(|e| e.to_string())?, std::ffi::CString::new(dest).map_err(|e| e.to_string())?);
        // CLONE_NOFOLLOW: the source is the file itself, never a link's target.
        // SAFETY: two NUL-terminated paths outliving the call.
        if unsafe { libc::clonefile(s.as_ptr(), d.as_ptr(), 0x0001) } == 0 {
            tell(total, total)?;
            return Ok(0);
        }
    }
    let mut to = std::fs::OpenOptions::new().write(true).create_new(true).open(dest).map_err(fail(dest))?;
    const STEP: usize = 8 << 20;
    let mut done = 0u64;
    tell(0, total)?;
    #[cfg(target_os = "linux")]
    {
        use std::os::unix::io::AsRawFd;
        loop {
            // SAFETY: two open descriptors; null offsets use and advance their own.
            let n = unsafe {
                libc::copy_file_range(from.as_raw_fd(), std::ptr::null_mut(), to.as_raw_fd(), std::ptr::null_mut(), STEP, 0)
            };
            if n < 0 {
                let e = std::io::Error::last_os_error();
                if done == 0 && matches!(e.raw_os_error(), Some(libc::EXDEV | libc::ENOSYS | libc::EINVAL | libc::EOPNOTSUPP)) {
                    break;
                }
                return Err(fail(dest)(e));
            }
            if n == 0 {
                return finish_copy(&to, &meta, dest);
            }
            done += n as u64;
            tell(done, total)?;
        }
    }
    let mut buf = vec![0u8; 1 << 20];
    loop {
        let n = from.read(&mut buf).map_err(fail(src))?;
        if n == 0 {
            return finish_copy(&to, &meta, dest);
        }
        to.write_all(&buf[..n]).map_err(fail(dest))?;
        done += n as u64;
        if done % (STEP as u64) < (n as u64) {
            tell(done, total)?;
        }
    }
}

/// Flushes the copy and gives it the source's permission bits.
fn finish_copy(to: &std::fs::File, meta: &std::fs::Metadata, dest: &str) -> Result<i32, String> {
    to.set_permissions(meta.permissions()).map_err(|e| format!("{}: {}", dest, e))?;
    Ok(0)
}

/// Names this process has claimed, across all its isolates and threads: the in-process
/// half of exclusive file locking, where the OS lock is the process's own.
static CLAIMS: std::sync::Mutex<std::collections::BTreeSet<String>> = std::sync::Mutex::new(std::collections::BTreeSet::new());

/// Claims `name`: 1 when free, 0 when another part of this process holds it.
#[no_mangle]
pub unsafe extern "C" fn tk_claim(name: *const u8, nlen: usize) -> i32 {
    guard(|| {
        let name = text(name, nlen)?.to_string();
        let mut claims = CLAIMS.lock().unwrap_or_else(|e| e.into_inner());
        Ok(i32::from(claims.insert(name)))
    })
}

/// Gives up a claim [`tk_claim`] made.
#[no_mangle]
pub unsafe extern "C" fn tk_unclaim(name: *const u8, nlen: usize) -> i32 {
    guard(|| {
        let name = text(name, nlen)?;
        CLAIMS.lock().unwrap_or_else(|e| e.into_inner()).remove(name);
        Ok(0)
    })
}
