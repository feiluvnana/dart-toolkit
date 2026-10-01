//! dart_toolkit_native: one flat C ABI for the toolkit's crypto and archive needs.
//!
//! Bytes cross as (pointer, length); text as UTF-8 (pointer, length); results are written into
//! caller buffers or, for variable-size JSON, into a Rust allocation the caller frees with
//! `tk_free`. Every function returns a negative code on failure and leaves a message for
//! `tk_last_error`. No callbacks into Dart.

use std::cell::RefCell;
use std::ffi::c_void;
use std::io::{Read, Write};
use std::path::Path;
use std::slice;

mod archive;
mod digest;
mod inflate;
mod text;

// Thread-local, which is sound only because every caller reads the message in the same
// synchronous block as the call that failed. Dart does not promise an isolate keeps one OS
// thread across message-loop turns, so never put an `await` between a failing call and its
// `tk_last_error`.
thread_local! {
    static LAST_ERROR: RefCell<String> = RefCell::new(String::new());
}

pub(crate) fn set_error(msg: &str) {
    LAST_ERROR.with(|e| *e.borrow_mut() = msg.to_string());
}

/// Runs `f`, storing its error message for `tk_last_error` and mapping it to -1.
pub(crate) fn guard(f: impl FnOnce() -> Result<i32, String>) -> i32 {
    static PANIC_HOOK: std::sync::Once = std::sync::Once::new();
    PANIC_HOOK.call_once(|| {
        std::panic::set_hook(Box::new(|info| {
            let msg = if let Some(s) = info.payload().downcast_ref::<&str>() {
                s.to_string()
            } else if let Some(s) = info.payload().downcast_ref::<String>() {
                s.clone()
            } else {
                "native panic".to_string()
            };
            set_error(&msg);
        }));
    });

    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)) {
        Ok(Ok(n)) => n,
        Ok(Err(m)) => {
            set_error(&m);
            -1
        }
        Err(_) => -2,
    }
}

pub(crate) unsafe fn bytes<'a>(ptr: *const u8, len: usize) -> &'a [u8] {
    if ptr.is_null() || len == 0 {
        &[]
    } else {
        slice::from_raw_parts(ptr, len)
    }
}

pub(crate) unsafe fn bytes_mut<'a>(ptr: *mut u8, len: usize) -> &'a mut [u8] {
    if ptr.is_null() || len == 0 {
        &mut []
    } else {
        slice::from_raw_parts_mut(ptr, len)
    }
}

pub(crate) unsafe fn text<'a>(ptr: *const u8, len: usize) -> Result<&'a str, String> {
    std::str::from_utf8(bytes(ptr, len)).map_err(|_| "text is not UTF-8".to_string())
}

pub(crate) unsafe fn opt_text<'a>(ptr: *const u8, len: usize) -> Result<Option<&'a str>, String> {
    if ptr.is_null() {
        Ok(None)
    } else {
        text(ptr, len).map(Some)
    }
}

/// Hands `data` to the caller as a Rust allocation it frees with `tk_free`; writes pointer and
/// length, and returns 0. The length travels only in `out_len`: returned as an `i32` it went
/// negative past 2 GiB.
pub(crate) fn give(data: Vec<u8>, out_ptr: *mut *mut u8, out_len: *mut usize) -> i32 {
    let mut boxed = data.into_boxed_slice();
    let len = boxed.len();
    let ptr = boxed.as_mut_ptr();
    std::mem::forget(boxed);
    unsafe {
        *out_ptr = ptr;
        *out_len = len;
    }
    0
}

/// The ABI version; `NativeLib` refuses a library that reports another one. 3 added `tk_chmod`.
#[no_mangle]
pub extern "C" fn tk_version() -> u32 {
    3
}

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

/// Copies the last error message into `out` (up to `cap` bytes); returns its full length.
#[no_mangle]
pub unsafe extern "C" fn tk_last_error(out: *mut u8, cap: usize) -> i32 {
    LAST_ERROR.with(|e| {
        let msg = e.borrow();
        let b = msg.as_bytes();
        let n = b.len().min(cap);
        bytes_mut(out, n).copy_from_slice(&b[..n]);
        b.len() as i32
    })
}

/// Allocates `len` zeroed bytes, released with `tk_dealloc`.
///
/// Exported so the Dart side never has to look `malloc` up in the host process, which
/// `DynamicLibrary.process()` cannot do everywhere — and so Dart and Rust stop sharing an
/// allocator by coincidence.
#[no_mangle]
pub extern "C" fn tk_alloc(len: usize) -> *mut u8 {
    if len == 0 {
        return std::ptr::null_mut();
    }
    let mut buffer = vec![0u8; len];
    let ptr = buffer.as_mut_ptr();
    std::mem::forget(buffer);
    ptr
}

/// Releases what `tk_alloc` returned. `len` must be the length it was asked for.
#[no_mangle]
pub unsafe extern "C" fn tk_dealloc(ptr: *mut u8, len: usize) {
    if !ptr.is_null() && len != 0 {
        drop(Vec::from_raw_parts(ptr, len, len));
    }
}

#[no_mangle]
pub unsafe extern "C" fn tk_free(ptr: *mut u8, len: usize) {
    if !ptr.is_null() {
        drop(Box::from_raw(slice::from_raw_parts_mut(ptr, len)));
    }
}

/// Opaque handle used by the streaming digest.
pub type Handle = *mut c_void;

pub(crate) fn read_file(path: &str) -> Result<std::fs::File, String> {
    std::fs::File::open(path).map_err(|e| format!("{}: {}", path, e))
}

pub(crate) fn create_file(path: &str) -> Result<std::fs::File, String> {
    if let Some(parent) = Path::new(path).parent() {
        std::fs::create_dir_all(parent).map_err(|e| format!("{}: {}", parent.display(), e))?;
    }
    std::fs::File::create(path).map_err(|e| format!("{}: {}", path, e))
}

/// `.msg()`: any error as the message `tk_last_error` hands to Dart.
pub(crate) trait Msg<T> {
    fn msg(self) -> Result<T, String>;
}

impl<T, E: std::fmt::Display> Msg<T> for Result<T, E> {
    fn msg(self) -> Result<T, String> {
        self.map_err(|e| e.to_string())
    }
}

pub(crate) fn pump(mut from: impl Read, mut to: impl Write) -> Result<(), String> {
    std::io::copy(&mut from, &mut to).msg()?;
    to.flush().msg()
}
