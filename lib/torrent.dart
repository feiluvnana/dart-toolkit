/// # Torrents
///
/// A BitTorrent client (librqbit: trackers, DHT, PEX, magnets, uTP, LSD, resume, streaming),
/// `.torrent` files ([Metainfo]) and magnet links ([Magnet]), creating and verifying torrents,
/// and Bencode.
///
/// ```dart
/// final t = await Torrent.read('ubuntu.torrent');
/// await t.download(into: 'iso').show('Ubuntu');
/// ```
///
/// {@category Formats}
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'src/core.dart';
import 'src/native.dart';
import 'hash.dart';
import 'path.dart';

export 'core.dart';
export 'path.dart';
export 'src/native.dart' show NativeException;

part 'src/formats/torrent/bencode.dart';
part 'src/formats/torrent/client.dart';
part 'src/formats/torrent/native.dart';
part 'src/formats/torrent/torrent.dart';
