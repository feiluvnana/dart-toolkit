//! dart_toolkit_torrent: the BitTorrent engine (librqbit), apart from the main library so
//! a script that never downloads a torrent never loads it, and its rebuilds leave the main
//! one alone. Same conventions as dart_toolkit_native: see `tk_common`.

mod torrent;

tk_common::exports!(3);
