//! `dart_toolkit_tui`, native ABI 1: terminal ownership and input.
//!
//! Owns what Dart cannot do: raw mode, the alternate screen, bracketed paste
//! and mouse capture, and key/pointer/resize/paste parsing (crossterm). Layout,
//! the cell grid, the diff and its ANSI encoding all stay in Dart (the single
//! source of truth): this crate paints the bytes Dart hands it and reports
//! what it heard. Shares no code with the legacy tree.

mod term;

pub(crate) use tk_common::{guard, live, Handle, Msg};

tk_common::exports!(1);
