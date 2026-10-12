//! `dart_toolkit_tui`, native ABI 2: terminal ownership and input.
//!
//! Owns what Dart cannot do: raw mode, the alternate screen, bracketed paste
//! and mouse capture, and key/pointer/resize/paste parsing (crossterm), read
//! on a native thread that hands each event to a Dart listener. Layout, the
//! cell grid, the diff and its ANSI encoding all stay in Dart (the single
//! source of truth): this crate paints the bytes Dart hands it and reports
//! what it heard.

mod term;

pub(crate) use tk_common::{guard, live, Handle, Msg};

/// Locks `m`, ignoring poisoning: a panicked reader leaves the state as
/// consistent as each step left it, and the stop paths must still run.
pub(crate) fn lock<T>(m: &std::sync::Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

tk_common::exports!(2);
