//! `dart_toolkit_chrome`, native ABI 2: the browser engine.
//!
//! Owns what Dart cannot do safely — spawning Chrome hidden, refusing a held
//! profile, asking the OS whether a pid lives, killing the whole tree — and speaks
//! CDP over a blocking websocket (one short-lived connection per call). Every call
//! that waits on the browser is a job on the shared pool (`tk_common::spawn`): it
//! returns 0 once queued and reports through the caller's `done` callback, so the
//! caller's event loop never blocks. Only `alive`, `free`, the GC releases and
//! `attach_page` (in memory) stay synchronous.
//!
//! Handles come first: a launch or an open answers its handle at queue time, and
//! the job fills it in. A handle and its jobs share the state behind an `Arc`, so
//! closing one while a job runs is safe, and a job that finds its handle closed
//! cleans up what it made (a spawned browser, a created tab).

mod cdp;
mod chrome;

pub(crate) use tk_common::{guard, live, stopped, text, Done, Handle, Msg, Progress};

tk_common::exports!(2);

/// Locks `m`, ignoring poisoning: a panicked job leaves the state as consistent
/// as each step left it, and the close paths must still run.
pub(crate) fn lock<T>(m: &std::sync::Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// What a closed handle's job fails with (Dart has already answered the caller).
pub(crate) const CLOSED: &str = "closed";

/// Queues `work` on the job pool, watching `stop` for its whole run; a panic in
/// `work` becomes a failing job (its done callback always runs). Answers 0
/// (queued), or -1 with the error set when there is no `done` to report to.
pub(crate) fn queue(
    done: Done,
    stop: *const u8,
    work: impl FnOnce() -> Result<Vec<u8>, String> + Send + 'static,
) -> i32 {
    if done.is_none() {
        tk_common::set_error("a job needs its done callback");
        return -1;
    }
    // The stop byte stays alive until `done` runs (the caller frees it there).
    let stop = stop as usize;
    tk_common::spawn(done, move || {
        let _watch = unsafe { tk_common::watch(stop as *const u8) };
        match std::panic::catch_unwind(std::panic::AssertUnwindSafe(work)) {
            Ok(Ok(out)) => Ok(tk_common::done_bytes(out)),
            Ok(Err(message)) => Err(message),
            Err(payload) => Err(match (payload.downcast_ref::<&str>(), payload.downcast_ref::<String>()) {
                (Some(s), _) => s.to_string(),
                (_, Some(s)) => s.clone(),
                _ => "native panic".to_string(),
            }),
        }
    });
    0
}
