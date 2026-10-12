//! `tk_common`: the foundation every `native` cdylib links in.
//!
//! The native contract every library shares (CONVENTIONS rule 44):
//! the error slot, the guard mapping failures to negative codes, `(pointer, length)`
//! views, the caller-owned allocator, opaque handles, and the stop flag that lets a
//! long call end early. Linked into each cdylib separately, so every library keeps its
//! own error slot and heap. Shares no code with the deleted legacy tree.

use std::cell::RefCell;
use std::ffi::c_void;
use std::path::Path;
use std::slice;

// Thread-local: sound only because the caller reads the slot in the same synchronous
// block as the failing call. Never hold across an `await` on the Dart side.
thread_local! {
    static LAST_ERROR: RefCell<String> = RefCell::new(String::new());
}

/// Records the message the next `tk_last_error` hands to the caller.
pub fn set_error(msg: &str) {
    LAST_ERROR.with(|slot| *slot.borrow_mut() = msg.to_string());
}

// The stop flag for the long call running on this thread: one byte the caller owns for
// the whole call and may set from another thread. Thread-local like `LAST_ERROR`.
thread_local! {
    static STOP: std::cell::Cell<*const std::sync::atomic::AtomicU8> =
        const { std::cell::Cell::new(std::ptr::null()) };
}

/// What a stopped call fails with; the Dart side reads it as its own cancel.
pub const STOPPED: &str = "cancelled";

/// Watches `flag` (a caller-owned byte alive for the whole call; null for none) until
/// the returned guard drops, restoring whatever was watched before.
pub unsafe fn watch(flag: *const u8) -> Watch {
    Watch(STOP.with(|slot| slot.replace(flag as *const std::sync::atomic::AtomicU8)))
}

/// Restores the previously watched flag when dropped.
pub struct Watch(*const std::sync::atomic::AtomicU8);

impl Drop for Watch {
    fn drop(&mut self) {
        STOP.with(|slot| slot.set(self.0));
    }
}

/// `Err(STOPPED)` once the caller has set the flag this thread watches.
pub fn stopped() -> Result<(), String> {
    let flag = STOP.with(|slot| slot.get());
    // SAFETY: the caller keeps the byte alive until the call it was handed to returns.
    if !flag.is_null() && unsafe { (*flag).load(std::sync::atomic::Ordering::Relaxed) } != 0 {
        return Err(STOPPED.to_string());
    }
    Ok(())
}

/// A reader failing with [`STOPPED`] once the caller stops the call, so one large entry
/// or stream stops part way, not only between entries.
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

/// Runs `f`, storing its error for `tk_last_error` and mapping it to -1 (-2 for a
/// panic). A worker-thread panic is caught here; the hook stays silent so the message
/// travels through `tk_last_error`, never stderr.
pub fn guard(f: impl FnOnce() -> Result<i32, String>) -> i32 {
    static PANIC_HOOK: std::sync::Once = std::sync::Once::new();
    PANIC_HOOK.call_once(|| std::panic::set_hook(Box::new(|_| {})));
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)) {
        Ok(Ok(n)) => n,
        Ok(Err(message)) => {
            set_error(&message);
            -1
        }
        Err(payload) => {
            let message = match (payload.downcast_ref::<&str>(), payload.downcast_ref::<String>()) {
                (Some(s), _) => s.to_string(),
                (_, Some(s)) => s.clone(),
                _ => "native panic".to_string(),
            };
            set_error(&message);
            -2
        }
    }
}

/// The bytes at (`ptr`, `len`); a null pointer or zero length is the empty slice.
pub unsafe fn bytes<'a>(ptr: *const u8, len: usize) -> &'a [u8] {
    if ptr.is_null() || len == 0 {
        &[]
    } else {
        slice::from_raw_parts(ptr, len)
    }
}

/// The mutable bytes at (`ptr`, `len`).
pub unsafe fn bytes_mut<'a>(ptr: *mut u8, len: usize) -> &'a mut [u8] {
    if ptr.is_null() || len == 0 {
        &mut []
    } else {
        slice::from_raw_parts_mut(ptr, len)
    }
}

/// The UTF-8 text at (`ptr`, `len`).
pub unsafe fn text<'a>(ptr: *const u8, len: usize) -> Result<&'a str, String> {
    std::str::from_utf8(bytes(ptr, len)).map_err(|_| "text is not UTF-8".to_string())
}

/// The UTF-8 text at (`ptr`, `len`), or `None` for a null pointer.
pub unsafe fn opt_text<'a>(ptr: *const u8, len: usize) -> Result<Option<&'a str>, String> {
    if ptr.is_null() {
        Ok(None)
    } else {
        text(ptr, len).map(Some)
    }
}

/// Hands `data` to the caller as a Rust allocation freed with `tk_free`; its length
/// travels in `out_len`, never as an `i32` return (which would overflow past 2 GiB).
pub fn give(data: Vec<u8>, out_ptr: *mut *mut u8, out_len: *mut usize) -> i32 {
    let mut boxed = data.into_boxed_slice();
    let (ptr, len) = (boxed.as_mut_ptr(), boxed.len());
    std::mem::forget(boxed);
    unsafe {
        *out_ptr = ptr;
        *out_len = len;
    }
    0
}

/// Opaque streaming handle: a `*mut c_void` the Dart side never inspects.
pub type Handle = *mut c_void;

/// The `T` a handle points at, or an error for a null one.
pub unsafe fn live<'a, T>(handle: Handle) -> Result<&'a mut T, String> {
    if handle.is_null() {
        return Err("null handle".to_string());
    }
    Ok(&mut *(handle as *mut T))
}

/// Opens the file at `path`; the error names it as `<path>: <os words> (os error N)`,
/// which the Dart side maps to its typed file exceptions.
pub fn read_file(path: &str) -> Result<std::fs::File, String> {
    std::fs::File::open(path).map_err(|e| format!("{}: {}", path, e))
}

/// Creates the file at `path`, making its parent folders first.
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

/// Copies the last error message into `out` (up to `cap` bytes); answers its full length.
pub unsafe fn last_error(out: *mut u8, cap: usize) -> i32 {
    LAST_ERROR.with(|slot| {
        let message = slot.borrow();
        let raw = message.as_bytes();
        let n = raw.len().min(cap);
        bytes_mut(out, n).copy_from_slice(&raw[..n]);
        raw.len() as i32
    })
}

/// `len` uninitialized bytes, released with [`dealloc`].
pub fn alloc(len: usize) -> *mut u8 {
    if len == 0 {
        return std::ptr::null_mut();
    }
    match std::alloc::Layout::array::<u8>(len) {
        Ok(layout) => unsafe { std::alloc::alloc(layout) },
        Err(_) => std::ptr::null_mut(),
    }
}

/// Releases what [`alloc`] returned. `len` must be the length it was asked for.
pub unsafe fn dealloc(ptr: *mut u8, len: usize) {
    if !ptr.is_null() && len != 0 {
        if let Ok(layout) = std::alloc::Layout::array::<u8>(len) {
            std::alloc::dealloc(ptr, layout);
        }
    }
}

/// Releases what [`give`] handed out.
pub unsafe fn free(ptr: *mut u8, len: usize) {
    if !ptr.is_null() {
        drop(Box::from_raw(slice::from_raw_parts_mut(ptr, len)));
    }
}

/// The five exports every library carries: its ABI version, its last error, its
/// allocator. Expanded in the cdylib itself, because a dependency's `#[no_mangle]`
/// is not reliably exported under `lto = "fat"`.
#[macro_export]
macro_rules! exports {
    ($version:expr) => {
        /// The ABI version; the Dart loader refuses a library reporting another one.
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
        $crate::jobs!();
    };
}

// ---- long calls on worker threads (the job protocol)

// (The `jobs!()` macro above expands the four job exports in each cdylib.)

/// A long call's outcome, held until Dart takes it: `rc` carries a small
/// integer answer (a count, 0 for ok) or a negative error, `out` carries
/// bytes, `err` the message. The error stays on the job, never in the
/// thread-local slot, because the work ran on another thread.
pub struct Job {
    /// The outcome: a count or 0 on success, negative on failure.
    pub rc: i32,
    /// The outcome bytes on success.
    pub out: Vec<u8>,
    /// The failure message.
    pub err: String,
}

/// A long call's end, invoked once from the worker thread with the job held.
/// Dart takes the outcome (`tk_job_rc/take/error`) and frees it (`tk_job_free`).
pub type Done = Option<unsafe extern "C" fn(job: *mut Job)>;

/// Progress from the worker thread: Dart's `id`, units done and total.
pub type Progress = Option<unsafe extern "C" fn(id: i64, done: u64, total: u64)>;

/// One unit of pool work.
type Task = Box<dyn FnOnce() + Send + 'static>;

/// The shared worker pool: one thread per CPU, at least two. Long calls run
/// here, never on the caller's thread, so the event loop stays responsive.
fn pool() -> &'static std::sync::mpsc::Sender<Task> {
    static POOL: std::sync::OnceLock<(std::sync::mpsc::Sender<Task>, Vec<std::thread::JoinHandle<()>>)> =
        std::sync::OnceLock::new();
    &POOL
        .get_or_init(|| {
            let (tx, rx) = std::sync::mpsc::channel::<Task>();
            let rx = std::sync::Arc::new(std::sync::Mutex::new(rx));
            let n = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(2).max(2);
            let mut workers = Vec::with_capacity(n);
            for _ in 0..n {
                let rx = rx.clone();
                workers.push(std::thread::spawn(move || loop {
                    let task = rx.lock().expect("job pool gone").recv();
                    match task {
                        Ok(work) => {
                            // A panicking job must not take its worker down.
                            let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(work));
                        }
                        Err(_) => break,
                    }
                }));
            }
            (tx, workers)
        })
        .0
}

/// Runs `work` on the shared pool, then calls `done` with its job. A panic in
/// `work` becomes a failing job, never a lost thread.
pub fn spawn(done: Done, work: impl FnOnce() -> Result<Job, String> + Send + 'static) {
    let done = done.expect("a job needs its done callback");
    pool()
        .send(Box::new(move || {
            let job = match work() {
                Ok(job) => job,
                Err(err) => Job { rc: -1, out: Vec::new(), err },
            };
            unsafe { done(Box::into_raw(Box::new(job))) };
        }))
        .expect("job pool gone");
}

/// A successful job carrying `out` bytes.
pub fn done_bytes(out: Vec<u8>) -> Job {
    Job { rc: 0, out, err: String::new() }
}

/// A successful job carrying the count `n`.
pub fn done_count(n: i32) -> Job {
    Job { rc: n, out: Vec::new(), err: String::new() }
}

/// Reads the job's outcome code (a count, 0, or negative).
/// SAFETY: `j` is a live job handed to a `Done` callback.
pub unsafe fn job_rc(j: *mut Job) -> i32 {
    if j.is_null() {
        return -1;
    }
    (*j).rc
}

/// Hands the job's bytes to the caller (`give` buffer, freed with `tk_free`);
/// a failed job answers its code instead.
pub unsafe fn job_take(j: *mut Job, out: *mut *mut u8, len: *mut usize) -> i32 {
    if j.is_null() || out.is_null() || len.is_null() {
        return -1;
    }
    let job = &mut *j;
    if job.rc < 0 {
        return job.rc;
    }
    let mut boxed = std::mem::take(&mut job.out).into_boxed_slice();
    *out = boxed.as_mut_ptr();
    *len = boxed.len();
    std::mem::forget(boxed);
    0
}

/// Copies the job's error message into `buf` (up to `cap`); answers its full length.
pub unsafe fn job_error(j: *mut Job, buf: *mut u8, cap: usize) -> i32 {
    if j.is_null() {
        return -1;
    }
    let raw = (*j).err.as_bytes();
    let n = raw.len().min(cap);
    bytes_mut(buf, n).copy_from_slice(&raw[..n]);
    raw.len() as i32
}

/// Releases a job taken by a `Done` callback.
pub unsafe fn job_free(j: *mut Job) {
    if !j.is_null() {
        drop(Box::from_raw(j));
    }
}

/// The four job exports every long-call library carries. Expanded in the
/// cdylib itself, like [`exports`].
#[macro_export]
macro_rules! jobs {
    () => {
        /// A taken job's outcome code.
        #[no_mangle]
        pub unsafe extern "C" fn tk_job_rc(j: *mut $crate::Job) -> i32 {
            $crate::job_rc(j)
        }
        /// A taken job's bytes (`give` buffer); a failed job answers its code.
        #[no_mangle]
        pub unsafe extern "C" fn tk_job_take(
            j: *mut $crate::Job,
            out: *mut *mut u8,
            len: *mut usize,
        ) -> i32 {
            $crate::job_take(j, out, len)
        }
        /// A taken job's error message into `buf`; answers its full length.
        #[no_mangle]
        pub unsafe extern "C" fn tk_job_error(j: *mut $crate::Job, buf: *mut u8, cap: usize) -> i32 {
            $crate::job_error(j, buf, cap)
        }
        /// Releases a job taken by a `Done` callback.
        #[no_mangle]
        pub unsafe extern "C" fn tk_job_free(j: *mut $crate::Job) {
            $crate::job_free(j)
        }
    };
}

/// Reports throttled progress: at most every 50 ms, plus the final
/// `done == total`. `last` tracks the previous report.
pub fn throttle_progress(
    cb: Progress,
    id: i64,
    done: u64,
    total: u64,
    last: &mut std::time::Instant,
) {
    let Some(f) = cb else {
        return;
    };
    let now = std::time::Instant::now();
    if done >= total || now.duration_since(*last) >= std::time::Duration::from_millis(50) {
        *last = now;
        unsafe {
            f(id, done, total);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn guard_maps_errors_and_panics() {
        assert_eq!(guard(|| Ok(7)), 7);
        assert_eq!(guard(|| Err("nope".to_string())), -1);
        assert_eq!(guard(|| -> Result<i32, String> { panic!("boom") }), -2);
    }

    #[test]
    fn stop_flag_trips_and_restores() {
        let flag = std::sync::atomic::AtomicU8::new(0);
        unsafe {
            let _watch = watch(&flag as *const _ as *const u8);
            assert!(stopped().is_ok());
            flag.store(1, std::sync::atomic::Ordering::Relaxed);
            assert_eq!(stopped().unwrap_err(), STOPPED);
        }
        // Dropped the watch: the flag is unwatched again.
        assert!(stopped().is_ok());
    }

    #[test]
    fn text_views_reject_non_utf8() {
        let good = b"hello";
        assert_eq!(unsafe { text(good.as_ptr(), good.len()).unwrap() }, "hello");
        let bad = [0xFFu8, 0xFE];
        assert!(unsafe { text(bad.as_ptr(), bad.len()) }.is_err());
        assert!(unsafe { opt_text(std::ptr::null(), 0) }.unwrap().is_none());
    }
}
