//! `dart_toolkit_torrent`, rewritten (native2 ABI 1).
//!
//! Fresh implementation of the torrent client surface over librqbit; shares no code with
//! legacy `native/torrent`. Same FFI names, signatures and JSON shapes, differential-tested
//! through the Dart client.

mod torrent;

tk_common::exports!(1);
