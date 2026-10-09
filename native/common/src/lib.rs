//! What every native library of the package shares: the error slot, the guard that maps a
//! failure to a negative code, (pointer, length) views, and the allocator Dart frees through.
//! Linked into each `cdylib` separately, so each library has its own error slot and heap.

use std::cell::RefCell;
use std::ffi::c_void;
use std::path::Path;
use std::slice;

// Thread-local: sound only because the caller reads it in the same synchronous block as the
// failing call. An isolate may change OS thread across an `await`, so never put one between.
thread_local! {
    static LAST_ERROR: RefCell<String> = RefCell::new(String::new());
}

pub fn set_error(msg: &str) {
    LAST_ERROR.with(|e| *e.borrow_mut() = msg.to_string());
}

// The caller's stop flag for the long call running on this thread: one byte the caller sets
// to non-zero from another thread. Thread-local for the same reason as `LAST_ERROR`.
thread_local! {
    static STOP: std::cell::Cell<*const std::sync::atomic::AtomicU8> = const { std::cell::Cell::new(std::ptr::null()) };
}

/// What a stopped call fails with: the caller reads it as its own cancel.
pub const STOPPED: &str = "cancelled";

/// Watches `flag` (a byte the caller owns for the whole call; null for none) until the guard
/// drops: [stopped] answers from it on this thread.
pub unsafe fn watch(flag: *const u8) -> Watch {
    Watch(STOP.with(|s| s.replace(flag as *const std::sync::atomic::AtomicU8)))
}

/// Restores the flag watched before, when dropped.
pub struct Watch(*const std::sync::atomic::AtomicU8);

impl Drop for Watch {
    fn drop(&mut self) {
        STOP.with(|s| s.set(self.0));
    }
}

/// `Err(STOPPED)` once the caller has set the flag this thread watches.
pub fn stopped() -> Result<(), String> {
    let flag = STOP.with(|s| s.get());
    // SAFETY: the caller keeps the byte alive until the call it was handed to returns.
    if !flag.is_null() && unsafe { (*flag).load(std::sync::atomic::Ordering::Relaxed) } != 0 {
        return Err(STOPPED.to_string());
    }
    Ok(())
}

/// A reader that fails with [STOPPED] once the caller stops the call: what lets one large
/// entry or stream stop part way, not only between entries.
pub struct Watched<R>(pub R);

impl<R: std::io::Read> std::io::Read for Watched<R> {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        stopped().map_err(std::io::Error::other)?;
        self.0.read(buf)
    }
}

impl<R: std::io::Seek> std::io::Seek for Watched<R> {
    fn seek(&mut self, pos: std::io::SeekFrom) -> std::io::Result<u64> {
        self.0.seek(pos)
    }
}

/// Runs `f`, storing its error message for `tk_last_error` and mapping it to -1, or -2 for a
/// panic. The message is taken from the payload on this thread: a rayon worker's panic
/// reaches here resumed, and a hook would have recorded it on the worker's thread.
pub fn guard(f: impl FnOnce() -> Result<i32, String>) -> i32 {
    static PANIC_HOOK: std::sync::Once = std::sync::Once::new();
    // Silent: the message travels through `tk_last_error`, not stderr.
    PANIC_HOOK.call_once(|| std::panic::set_hook(Box::new(|_| {})));
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)) {
        Ok(Ok(n)) => n,
        Ok(Err(m)) => {
            set_error(&m);
            -1
        }
        Err(payload) => {
            let msg = match (payload.downcast_ref::<&str>(), payload.downcast_ref::<String>()) {
                (Some(s), _) => s.to_string(),
                (_, Some(s)) => s.clone(),
                _ => "native panic".to_string(),
            };
            set_error(&msg);
            -2
        }
    }
}

pub unsafe fn bytes<'a>(ptr: *const u8, len: usize) -> &'a [u8] {
    if ptr.is_null() || len == 0 {
        &[]
    } else {
        slice::from_raw_parts(ptr, len)
    }
}

pub unsafe fn bytes_mut<'a>(ptr: *mut u8, len: usize) -> &'a mut [u8] {
    if ptr.is_null() || len == 0 {
        &mut []
    } else {
        slice::from_raw_parts_mut(ptr, len)
    }
}

pub unsafe fn text<'a>(ptr: *const u8, len: usize) -> Result<&'a str, String> {
    std::str::from_utf8(bytes(ptr, len)).map_err(|_| "text is not UTF-8".to_string())
}

pub unsafe fn opt_text<'a>(ptr: *const u8, len: usize) -> Result<Option<&'a str>, String> {
    if ptr.is_null() {
        Ok(None)
    } else {
        text(ptr, len).map(Some)
    }
}

/// Hands `data` to the caller as a Rust allocation it frees with `tk_free`, and returns 0.
/// The length travels in `out_len`, never as an `i32` return, which would overflow past 2 GiB.
pub fn give(data: Vec<u8>, out_ptr: *mut *mut u8, out_len: *mut usize) -> i32 {
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

/// Opaque handle used by the streaming digest.
pub type Handle = *mut c_void;

/// The `T` a handle points at, or an error for a null one.
pub unsafe fn live<'a, T>(h: Handle) -> Result<&'a mut T, String> {
    if h.is_null() {
        return Err("null handle".to_string());
    }
    Ok(&mut *(h as *mut T))
}

pub fn read_file(path: &str) -> Result<std::fs::File, String> {
    std::fs::File::open(path).map_err(|e| format!("{}: {}", path, e))
}

pub fn create_file(path: &str) -> Result<std::fs::File, String> {
    if let Some(parent) = Path::new(path).parent() {
        std::fs::create_dir_all(parent).map_err(|e| format!("{}: {}", parent.display(), e))?;
    }
    std::fs::File::create(path).map_err(|e| format!("{}: {}", path, e))
}

/// `.msg()`: any error as the message `tk_last_error` hands to Dart.
pub trait Msg<T> {
    fn msg(self) -> Result<T, String>;
}

impl<T, E: std::fmt::Display> Msg<T> for Result<T, E> {
    fn msg(self) -> Result<T, String> {
        self.map_err(|e| e.to_string())
    }
}

/// Copies the last error message into `out` (up to `cap` bytes); returns its full length.
pub unsafe fn last_error(out: *mut u8, cap: usize) -> i32 {
    LAST_ERROR.with(|e| {
        let msg = e.borrow();
        let b = msg.as_bytes();
        let n = b.len().min(cap);
        bytes_mut(out, n).copy_from_slice(&b[..n]);
        b.len() as i32
    })
}

/// `len` uninitialized bytes, released with [dealloc].
pub fn alloc(len: usize) -> *mut u8 {
    if len == 0 {
        return std::ptr::null_mut();
    }
    let layout = match std::alloc::Layout::array::<u8>(len) {
        Ok(l) => l,
        Err(_) => return std::ptr::null_mut(),
    };
    unsafe { std::alloc::alloc(layout) }
}

/// Releases what [alloc] returned. `len` must be the length it was asked for.
pub unsafe fn dealloc(ptr: *mut u8, len: usize) {
    if !ptr.is_null() && len != 0 {
        if let Ok(layout) = std::alloc::Layout::array::<u8>(len) {
            std::alloc::dealloc(ptr, layout);
        }
    }
}

/// Releases what [give] handed out.
pub unsafe fn free(ptr: *mut u8, len: usize) {
    if !ptr.is_null() {
        drop(Box::from_raw(slice::from_raw_parts_mut(ptr, len)));
    }
}

/// The five exports every library has: its ABI version, its last error and its allocator.
/// Expanded in the `cdylib` itself, because a dependency's `#[no_mangle]` is not reliably
/// exported under `lto = "fat"`.
#[macro_export]
macro_rules! exports {
    ($version:expr) => {
        /// The ABI version; the Dart loader refuses a library that reports another one.
        #[no_mangle]
        pub extern "C" fn tk_version() -> u32 {
            $version
        }
        #[no_mangle]
        pub unsafe extern "C" fn tk_last_error(out: *mut u8, cap: usize) -> i32 {
            $crate::last_error(out, cap)
        }
        #[no_mangle]
        pub extern "C" fn tk_alloc(len: usize) -> *mut u8 {
            $crate::alloc(len)
        }
        #[no_mangle]
        pub unsafe extern "C" fn tk_dealloc(ptr: *mut u8, len: usize) {
            $crate::dealloc(ptr, len)
        }
        #[no_mangle]
        pub unsafe extern "C" fn tk_free(ptr: *mut u8, len: usize) {
            $crate::free(ptr, len)
        }
    };
}
