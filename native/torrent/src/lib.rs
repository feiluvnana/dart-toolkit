//! `dart_toolkit_torrent`, rewritten (native ABI 1).
//!
//! Fresh implementation of the torrent client surface over librqbit; shares no code with
//! the deleted legacy tree. Same FFI names, signatures and JSON shapes, differential-tested
//! through the Dart client.

mod torrent;

tk_common::exports!(1);
