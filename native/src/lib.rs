//! dart_toolkit_native: one flat C ABI for the toolkit's crypto and archive needs.
//!
//! Bytes cross as (pointer, length); text as UTF-8 (pointer, length); results are written into
//! caller buffers or, for variable-size JSON, into a Rust allocation the caller frees with
//! `tk_free`. Every function returns a negative code on failure and leaves a message for
//! `tk_last_error`. Only the archive calls call back into Dart, with progress, and take null.

use std::io::{Read, Write};

mod archive;
mod digest;
mod image;
mod inflate;
mod text;
mod pieces;

pub(crate) use tk_common::{
    bytes, bytes_mut, create_file, give, guard, live, opt_text, read_file, set_error, stopped, text, watch, Handle, Msg,
    Watched,
};
tk_common::exports!(12);

/// Sets the permission bits of `path` to `mode`, through a link as chmod(2) does. Windows has
/// one bit of it: without the owner's write bit the file is read-only.
#[no_mangle]
pub unsafe extern "C" fn tk_chmod(path: *const u8, plen: usize, mode: u32) -> i32 {
    guard(|| {
        let path = text(path, plen)?;
        // The message is the OS's alone: the Dart side names the path.
        let err = |e: std::io::Error| e.to_string();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode & 0o7777)).map_err(err)?;
        }
        #[cfg(not(unix))]
        {
            let mut perms = std::fs::metadata(path).map_err(err)?.permissions();
            perms.set_readonly(mode & 0o200 == 0);
            std::fs::set_permissions(path, perms).map_err(err)?;
        }
        Ok(0)
    })
}

/// The identity of the file at `path`, as two numbers written to `out`: the device and inode on
/// Unix, the volume serial number and file index on Windows. A file renamed keeps it; another file
/// put in its place has another.
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
    use std::os::windows::io::AsRawHandle;
    #[repr(C)]
    #[derive(Default)]
    struct Info {
        attributes: u32,
        // FILETIMEs: two DWORDs each, 4-aligned, so no u64 here.
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
        fn GetFileInformationByHandle(file: *mut std::ffi::c_void, info: *mut Info) -> i32;
    }
    // Opened for no access at all: a log another process holds open for writing still answers.
    use std::os::windows::fs::OpenOptionsExt;
    let f = std::fs::OpenOptions::new().access_mode(0).share_mode(7).open(path)?;
    let mut info = Info::default();
    if unsafe { GetFileInformationByHandle(f.as_raw_handle() as *mut _, &mut info) } == 0 {
        return Err(std::io::Error::last_os_error());
    }
    Ok((info.volume as u64, ((info.index_high as u64) << 32) | info.index_low as u64))
}

/// Copies the file at `src` to `dest`, a new file (the caller's temporary, renamed into place
/// after): a clone where the file system makes one (APFS), else in chunks, in the kernel where it
/// can (Linux), telling `progress` the bytes so far and stopping once `stop` is set. The copy
/// gets the source's permission bits. A failed or stopped copy removes `dest`.
#[no_mangle]
pub unsafe extern "C" fn tk_copy_file(
    src: *const u8,
    slen: usize,
    dest: *const u8,
    dlen: usize,
    progress: archive::ProgressCb,
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

fn copy_file(src: &str, dest: &str, progress: archive::ProgressCb) -> Result<i32, String> {
    fn err(p: &str) -> impl Fn(std::io::Error) -> String + '_ {
        move |e| format!("{}: {}", p, e)
    }
    let tell = |done: u64, total: u64| -> Result<(), String> {
        if let Some(cb) = progress {
            unsafe { cb(0, 1, done, total, std::ptr::null(), 0) };
        }
        stopped()
    };
    let mut from = std::fs::File::open(src).map_err(err(src))?;
    let meta = from.metadata().map_err(err(src))?;
    let total = meta.len();
    #[cfg(target_os = "macos")]
    {
        let (s, d) = (std::ffi::CString::new(src).msg()?, std::ffi::CString::new(dest).msg()?);
        // CLONE_NOFOLLOW: the source is the file itself, never what a link at it points to.
        // SAFETY: two NUL-terminated paths that outlive the call.
        if unsafe { libc::clonefile(s.as_ptr(), d.as_ptr(), 0x0001) } == 0 {
            tell(total, total)?;
            return Ok(0);
        }
    }
    let mut to = std::fs::OpenOptions::new().write(true).create_new(true).open(dest).map_err(err(dest))?;
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
                // Not across these file systems, or not in this kernel: copied below instead.
                if done == 0 && matches!(e.raw_os_error(), Some(libc::EXDEV | libc::ENOSYS | libc::EINVAL | libc::EOPNOTSUPP)) {
                    break;
                }
                return Err(err(dest)(e));
            }
            if n == 0 {
                return finish(&to, &meta, dest);
            }
            done += n as u64;
            tell(done, total)?;
        }
    }
    let mut buf = vec![0u8; 1 << 20];
    loop {
        let n = from.read(&mut buf).map_err(err(src))?;
        if n == 0 {
            return finish(&to, &meta, dest);
        }
        to.write_all(&buf[..n]).map_err(err(dest))?;
        done += n as u64;
        if done % (STEP as u64) < (n as u64) {
            tell(done, total)?;
        }
    }
}

/// The copy flushed and given the source's permission bits.
fn finish(to: &std::fs::File, meta: &std::fs::Metadata, dest: &str) -> Result<i32, String> {
    to.set_permissions(meta.permissions()).map_err(|e| format!("{}: {}", dest, e))?;
    Ok(0)
}

/// The names this process has claimed, across all its isolates and threads: what makes a file
/// lock exclusive inside one process, where the operating system's lock is the process's own.
static CLAIMS: std::sync::Mutex<std::collections::BTreeSet<String>> = std::sync::Mutex::new(std::collections::BTreeSet::new());

/// Claims `name` for the caller: 1 when it was free, 0 when another part of this process holds
/// it. [tk_unclaim] gives it up; the process ending gives up all.
#[no_mangle]
pub unsafe extern "C" fn tk_claim(name: *const u8, nlen: usize) -> i32 {
    guard(|| {
        let name = text(name, nlen)?.to_string();
        let mut claims = CLAIMS.lock().unwrap_or_else(|e| e.into_inner());
        Ok(i32::from(claims.insert(name)))
    })
}

/// Gives up a claim [tk_claim] made.
#[no_mangle]
pub unsafe extern "C" fn tk_unclaim(name: *const u8, nlen: usize) -> i32 {
    guard(|| {
        let name = text(name, nlen)?;
        CLAIMS.lock().unwrap_or_else(|e| e.into_inner()).remove(name);
        Ok(0)
    })
}

pub(crate) fn pump(mut from: impl Read, mut to: impl Write) -> Result<(), String> {
    std::io::copy(&mut from, &mut to).msg()?;
    to.flush().msg()
}
