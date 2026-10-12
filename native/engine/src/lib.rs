//! `dart_toolkit_native`, rewritten (native ABI 2).
//!
//! Fresh implementation of the native engine contract; shares no code with the deleted
//! legacy tree. Bytes cross as (pointer, length), text as UTF-8, variable-size results
//! through caller buffers, `give()` allocations freed with `tk_free`, or `own()`
//! buffers freed with `tk_release`. Every function returns a negative code on failure
//! and leaves a message for `tk_last_error`.

mod archive;
mod digest;
mod handover;
mod image;
mod inflate;
mod pieces;
mod process;
mod sys;
mod text;

pub(crate) use tk_common::{
    bytes, bytes_mut, create_file, give, guard, live, opt_text, read_file, set_error, stopped, text, watch,
    Handle, Msg, Watched,
};
pub(crate) use tk_common::{Done, Job, Progress, done_bytes, done_count, spawn, throttle_progress};

/// Pumps `from` into `to` until end, then flushes.
pub(crate) fn pump(mut from: impl std::io::Read, mut to: impl std::io::Write) -> Result<(), String> {
    std::io::copy(&mut from, &mut to).map_err(|e| e.to_string())?;
    to.flush().map_err(|e| e.to_string())
}
tk_common::exports!(3);
