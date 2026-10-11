//! `dart_toolkit_chrome`, native2 ABI 1: the browser engine.
//!
//! Owns what Dart cannot do safely — spawning Chrome hidden, refusing a held
//! profile, asking the OS whether a pid lives, killing the whole tree — and speaks
//! CDP over a blocking websocket (one short-lived connection per call). Bytes cross
//! as (pointer, length), text as UTF-8, captures through `give()` allocations freed
//! with `tk_free`. Shares no code with the legacy tree.

mod cdp;
mod chrome;

pub(crate) use tk_common::{give, guard, live, stopped, text, Handle, Msg};

tk_common::exports!(1);
