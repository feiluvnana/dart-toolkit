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
mod crypto;

thread_local! {
    static LAST_ERROR: RefCell<String> = RefCell::new(String::new());
}


pub(crate) fn set_error(msg: &str) {
    LAST_ERROR.with(|e| *e.borrow_mut() = msg.to_string());
}

/// Runs `f`, storing its error message for `tk_last_error` and mapping it to -1.
pub(crate) fn guard(f: impl FnOnce() -> Result<i32, String>) -> i32 {
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)) {
        Ok(Ok(n)) => n,
        Ok(Err(m)) => {
            set_error(&m);
            -1
        }
        Err(_) => {
            set_error("native panic");
            -2
        }
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

/// Copies `data` into a Rust allocation the caller frees with `tk_free`; writes pointer and length.
pub(crate) fn give(data: Vec<u8>, out_ptr: *mut *mut u8, out_len: *mut usize) -> i32 {
    let mut boxed = data.into_boxed_slice();
    let len = boxed.len();
    let ptr = boxed.as_mut_ptr();
    std::mem::forget(boxed);
    unsafe {
        *out_ptr = ptr;
        *out_len = len;
    }
    len as i32
}

#[no_mangle]
pub extern "C" fn tk_version() -> u32 {
    1
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

pub(crate) fn pump(mut from: impl Read, mut to: impl Write) -> Result<(), String> {
    std::io::copy(&mut from, &mut to).map_err(|e| e.to_string())?;
    to.flush().map_err(|e| e.to_string())
}
