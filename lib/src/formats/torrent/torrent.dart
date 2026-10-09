part of '../../../torrent.dart';

/// A torrent: a [Metainfo] (a `.torrent` file, with every file and piece) or a [Magnet] (a
/// link, whose metadata comes from peers). Either downloads, and a [TorrentClient] adds either.
///
/// ```dart
/// await Torrent.read('ubuntu.torrent').download(into: 'iso').show('Ubuntu');
/// // or Torrent.decode(bytes), Torrent.parse(magnet)
/// ```
///
/// {@category Formats}
sealed class Torrent {
  const Torrent();

  /// The v1 info hash: 40 lowercase hex digits.
  String get infoHash;

  /// The name of its file or folder; a magnet's may be absent.
  String? get name;

  /// The trackers it announces to.
  List<Uri> get trackers;

  /// How a status names it: its name, else the start of its info hash.
  String get _label => name ?? infoHash.substring(0, 8);

  /// The `.torrent` file at [path]. A missing file is a [PathNotFoundException], a file that is
  /// not a torrent a [FormatException] naming it.
  static Future<Metainfo> read(String path) async {
    final bytes = await File(path).readAsBytes();
    try {
      return Metainfo._decode(bytes);
    } on FormatException catch (e) {
      throw FormatException('Invalid torrent in $path: ${_why(e)}', e.source, e.offset);
    }
  }

  /// The bytes of a `.torrent` file; bytes that are not one are a [FormatException].
  static Metainfo decode(List<int> bytes) {
    try {
      return Metainfo._decode(bytes);
    } on FormatException catch (e) {
      throw FormatException('Invalid torrent: ${_why(e)}', e.source, e.offset);
    }
  }

  /// The magnet link [link] (BEP 9: a hex or base32 v1 info hash, `dn`, `tr`, `xl`); one
  /// without a v1 hash is a [FormatException].
  static Magnet parse(String link) => Magnet._parse(link);

  /// Why [e] says the bytes are no torrent, without a bencode error's own `Invalid `.
  static String _why(FormatException e) =>
      e.message.startsWith('Invalid ') ? e.message.substring('Invalid '.length) : e.message;

  /// The `.torrent` for the file or folder at [path]: its files in sorted order (so the same
  /// folder makes the same info hash anywhere; `.DS_Store`, `Thumbs.db`, `desktop.ini` and `._*`
  /// left out), pieces hashed natively in parallel, reporting the bytes hashed. Announced to
  /// [trackers], in pieces of [pieceLength] bytes (a power of two, chosen from the size when
  /// omitted), named [name] (the file or folder's own), with [comment]. [private] keeps it off
  /// DHT and peer exchange, which changes its info hash.
  static Task<Metainfo> create(
    String path, {
    List<Uri> trackers = const [],
    int? pieceLength,
    String? name,
    bool private = false,
    String? comment,
  }) {
    if (pieceLength != null && (pieceLength < 1 || pieceLength & (pieceLength - 1) != 0)) {
      throw ArgumentError.value(pieceLength, 'pieceLength', 'Invalid piece length, expected a power of two');
    }
    return TaskInternals.start(Path(path), FileBridge.label(path), (work) async {
      work.step('listing');
      return _create(work, Path(path), trackers, pieceLength, name, private, comment);
    });
  }

  /// This torrent downloaded into the folder [into], by a client started for it and closed
  /// after: a single file lands at `into/<name>`, several in `into/<name>/`, and the task ends
  /// with that path (its steps `metadata`, `checking`, `downloading`). [files] picks file
  /// indices. Nothing seeds after it; for that, keep a [TorrentClient].
  Task<Path> download({required String into, List<int>? files}) => TaskInternals.start(this, _label, (work) async {
    final client = await TorrentClient.start(into: into);
    work.defer(client.close);
    return client.add(this, files: files);
  });
}

/// Downloading the torrent a read ends in.
///
/// {@category Formats}
extension TorrentFuture on Future<Torrent> {
  /// The torrent this ends in, downloaded as [Torrent.download] downloads it:
  /// `await Torrent.read('a.torrent').download(into: 'iso')`.
  Task<Path> download({required String into, List<int>? files}) => TaskInternals.start(
    Path(into),
    FileBridge.label(into),
    (work) async => (await this).download(into: into, files: files),
  );
}

/// A magnet link: what a torrent is called, its metadata still to come from peers.
///
/// {@category Formats}
final class Magnet extends Torrent {
  @override
  final String infoHash;

  @override
  final String? name;

  @override
  final List<Uri> trackers;

  /// The size it says, in bytes (`xl`).
  final int? size;

  /// The link, every parameter kept.
  final Uri uri;

  const Magnet._(this.infoHash, this.name, this.trackers, this.size, this.uri);

  static Magnet _parse(String link) {
    Never fail(String why) => throw FormatException('Invalid magnet link: $why', link);
    final uri = Uri.tryParse(link.trim());
    if (uri == null || uri.scheme != 'magnet') fail('not a magnet: link');
    final params = <String, List<String>>{};
    for (final pair in uri.query.split('&')) {
      if (pair.isEmpty) continue;
      final eq = pair.indexOf('=');
      final key = Uri.decodeQueryComponent(eq < 0 ? pair : pair.substring(0, eq));
      (params[key] ??= []).add(Uri.decodeQueryComponent(eq < 0 ? '' : pair.substring(eq + 1)));
    }
    String? hash;
    var v2 = false;
    for (final xt in params['xt'] ?? const <String>[]) {
      if (xt.startsWith('urn:btmh:')) v2 = true;
      if (!xt.startsWith('urn:btih:')) continue;
      final raw = xt.substring(9).trim();
      if (raw.length == 40 && RegExp(r'^[0-9a-fA-F]{40}$').hasMatch(raw)) {
        hash = raw.toLowerCase();
      } else if (raw.length == 32) {
        if (!RegExp(r'^[A-Za-z2-7]{32}$').hasMatch(raw)) fail('the btih hash "$raw" is not base32');
        hash = raw.base32Bytes.hex;
      } else {
        fail('the btih hash "$raw" is not 40 hex digits nor 32 base32 ones');
      }
      break;
    }
    if (hash == null) fail(v2 ? 'v2-only (btmh), which this client cannot fetch' : 'no xt=urn:btih: parameter');
    return Magnet._(
      hash,
      params['dn']?.firstOrNull,
      List.unmodifiable([for (final t in params['tr'] ?? const <String>[]) ?Uri.tryParse(t)]),
      int.tryParse(params['xl']?.firstOrNull ?? ''),
      uri,
    );
  }

  /// The link, as it was given.
  @override
  String toString() => '$uri';

  @override
  bool operator ==(Object other) => other is Magnet && other.infoHash == infoHash;

  @override
  int get hashCode => infoHash.hashCode;
}

/// One file of a [Metainfo]: its [path] inside the torrent, its [size], and where it starts in
/// the torrent's bytes ([offset]).
///
/// {@category Formats}
final class TorrentFile {
  final Path path;
  final int size;
  final int offset;

  const TorrentFile({required this.path, required this.size, required this.offset});

  @override
  String toString() => '$path (${size.humanBytes})';

  @override
  bool operator ==(Object other) =>
      other is TorrentFile && path == other.path && size == other.size && offset == other.offset;

  @override
  int get hashCode => Object.hash(path, size, offset);
}

/// A `.torrent` file (BEP 3, BEP 12): every file and piece of a torrent. It keeps the bytes it
/// was read from, so [encode] and [save] give them back unchanged and the info hash with them.
///
/// {@category Formats}
final class Metainfo extends Torrent implements Saveable {
  @override
  final String name;

  @override
  final String infoHash;

  /// The size of each piece in bytes.
  final int pieceLength;

  /// Its files, in torrent order; BEP 47 padding files are left out.
  final List<TorrentFile> files;

  @override
  final List<Uri> trackers;

  final String? comment;
  final String? createdBy;
  final DateTime? creationDate;

  /// Whether it is private: no DHT nor peer exchange.
  final bool isPrivate;

  /// Whether it holds a folder of files (`into/<name>/…`) rather than one file (`into/<name>`).
  final bool isFolder;

  final Uint8List _bytes;

  /// Every piece's SHA-1, 20 bytes each.
  final Uint8List _pieces;

  /// Every file in torrent order with its size; a padding file's path is `null`.
  final List<(String?, int)> _parts;

  Metainfo._(
    this._bytes, {
    required this.name,
    required this.infoHash,
    required this.pieceLength,
    required this.files,
    required this.trackers,
    required this.comment,
    required this.createdBy,
    required this.creationDate,
    required this.isPrivate,
    required this.isFolder,
    required Uint8List pieces,
    required List<(String?, int)> parts,
  }) : _pieces = pieces,
       _parts = parts;

  /// The bytes of every file together.
  int get size => files.fold(0, (sum, f) => sum + f.size);

  /// How many pieces it has.
  int get pieceCount => _pieces.length ~/ 20;

  /// Each piece's SHA-1, in hex.
  List<String> get pieceHashes => [
    for (var i = 0; i < _pieces.length; i += 20) Uint8List.sublistView(_pieces, i, i + 20).hex,
  ];

  /// Its magnet link: info hash, name and trackers.
  Magnet get magnet => Torrent.parse(
    'magnet:?xt=urn:btih:$infoHash&dn=${Uri.encodeQueryComponent(name)}'
    '${trackers.map((t) => '&tr=${Uri.encodeQueryComponent('$t')}').join()}',
  );

  static Metainfo _decode(List<int> source) {
    final bytes = Uint8List.fromList(source);
    final decoder = _BencodeDecoder(bytes);
    final root = decoder.value(0);
    if (decoder.offset < bytes.length) decoder._fail('trailing bytes');
    Never fail(String why) => throw FormatException(why);
    if (root is! Map<String, Object>) fail('the root is not a dictionary');
    final info = root['info'];
    final span = decoder.info;
    if (info is! Map<String, Object> || span == null) fail('no "info" dictionary');
    final encoding = switch (root['encoding']) {
      final Uint8List e => ascii.decode(e, allowInvalid: true),
      _ => null,
    };
    String text(Object? utf8Form, Object? raw) => switch ((utf8Form, raw)) {
      (final Uint8List b, _) => utf8.decode(b, allowMalformed: true),
      (_, final Uint8List b) => _text(b, encoding),
      _ => '',
    };
    final name = text(info['name.utf-8'], info['name']);
    if (name.isEmpty) fail('no "name" in info');
    final pieceLength = info['piece length'];
    if (pieceLength is! int || pieceLength <= 0) fail('no valid "piece length"');
    final pieces = info['pieces'];
    if (pieces is! Uint8List || pieces.length % 20 != 0) fail('"pieces" is not a multiple of 20 bytes');
    final files = <TorrentFile>[];
    final parts = <(String?, int)>[];
    var offset = 0;
    final list = info['files'];
    if (list is List<Object>) {
      for (final f in list) {
        if (f is! Map<String, Object>) fail('a "files" entry is not a dictionary');
        final length = f['length'];
        if (length is! int || length < 0) fail('a file has no valid "length"');
        final segments = switch (f['path.utf-8'] ?? f['path']) {
          final List<Object> p => [
            for (final s in p)
              s is Uint8List
                  ? (f['path.utf-8'] != null ? utf8.decode(s, allowMalformed: true) : _text(s, encoding))
                  : fail('a path segment is not a string'),
          ],
          _ => fail('a file has no "path"'),
        };
        final attr = switch (f['attr']) {
          final Uint8List a => ascii.decode(a, allowInvalid: true),
          _ => '',
        };
        final padding = attr.contains('p') || segments.firstOrNull == '.pad';
        if (padding) {
          parts.add((null, length));
        } else {
          final path = segments.join('/');
          parts.add((path, length));
          files.add(TorrentFile(path: Path(path), size: length, offset: offset));
        }
        offset += length;
      }
    } else if (info['length'] case final int length when length >= 0) {
      parts.add((name, length));
      files.add(TorrentFile(path: Path(name), size: length, offset: 0));
      offset = length;
    } else {
      fail('neither "files" nor "length" in info');
    }
    final count = (offset + pieceLength - 1) ~/ pieceLength;
    if (pieces.length != count * 20) {
      fail(
        '${pieces.length ~/ 20} piece hashes for ${offset.humanBytes} in pieces of $pieceLength bytes, expected $count',
      );
    }
    final trackers = <Uri>{
      if (root['announce'] case final Uint8List a) ?Uri.tryParse(utf8.decode(a, allowMalformed: true)),
      if (root['announce-list'] case final List<Object> tiers)
        for (final tier in tiers)
          for (final t in tier is List<Object> ? tier : [tier])
            if (t is Uint8List && t.isNotEmpty) ?Uri.tryParse(utf8.decode(t, allowMalformed: true)),
    };
    String? textOf(String key) => switch (root[key]) {
      final Uint8List b => utf8.decode(b, allowMalformed: true),
      _ => null,
    };
    return Metainfo._(
      bytes,
      name: name,
      infoHash: Hash.sha1.bytes(Uint8List.sublistView(bytes, span.$1, span.$2)).hex,
      pieceLength: pieceLength,
      files: List.unmodifiable(files),
      trackers: List.unmodifiable(trackers),
      comment: textOf('comment'),
      createdBy: textOf('created by'),
      // A date past what a DateTime holds is no date, as in every client.
      creationDate: switch (root['creation date']) {
        final int s when s.abs() <= _maxSeconds => DateTime.fromMillisecondsSinceEpoch(s * 1000, isUtc: true),
        _ => null,
      },
      isPrivate: info['private'] == 1,
      isFolder: list is List<Object>,
      pieces: pieces,
      parts: List.unmodifiable(parts),
    );
  }

  /// The bytes it was read from, unchanged.
  Uint8List encode() => Uint8List.fromList(_bytes);

  /// Writes it to the `.torrent` file [to] as [encode] gives it, atomically.
  @override
  Task<Path> save(String to, {Conflict conflict = Conflict.overwrite}) =>
      FileBridge.save(to, conflict, 'torrent $name', () => [_bytes]);

  /// Its files under the folder [dir] (where `download(into: dir)` put them: `dir/<name>` for
  /// one file, `dir/<name>/…` for several) checked against its pieces, natively and in parallel
  /// on a worker, reporting the bytes checked. A missing, short or damaged file is in the
  /// result, never thrown.
  ///
  /// ```dart
  /// final check = await torrent.verify('downloads').show('Verifying');
  /// ```
  Task<Verification> verify(String dir) => TaskInternals.start(this, name, (work) async {
    final root = Path(dir) / name;
    String on(String path) => isFolder ? root / path : root;
    final files = jsonEncode([
      for (final (path, size) in _parts) [path == null ? '' : File(on(path)).absolute.path, size],
    ]);
    final ok = await NativeBridge.main.run(
      work,
      _verifyCall(files, pieceLength, _pieces, size + _padding),
      onProgress: (r) => work.amount(r.bytes, total: r.bytesTotal),
    );
    return _verification(ok, on);
  });

  int get _padding => _parts.where((p) => p.$1 == null).fold(0, (sum, p) => sum + p.$2);

  /// The result of a check whose pieces came out as [ok] (1 a match), the files found by [on].
  Future<Verification> _verification(Uint8List ok, String Function(String path) on) async {
    final count = pieceCount;
    final valid = [for (var i = 0; i < count; i++) ok[i] == 1];
    final total = size + _padding;
    final result = <FileVerification>[];
    for (final file in files) {
      final stat = await FileStat.stat(on('${file.path}'));
      final exists = stat.type == FileSystemEntityType.file;
      final offset = file.offset;
      final first = offset ~/ pieceLength;
      final last = file.size == 0 ? first - 1 : (offset + file.size - 1) ~/ pieceLength;
      final bad = [
        for (var i = first; i <= last && i < count; i++)
          if (!valid[i]) i,
      ];
      var verified = 0;
      if (exists) {
        for (var i = first; i <= last && i < count; i++) {
          if (!valid[i]) continue;
          final start = i * pieceLength, end = start + pieceLength > total ? total : start + pieceLength;
          verified += (end < offset + file.size ? end : offset + file.size) - (start > offset ? start : offset);
        }
      }
      result.add(
        FileVerification(
          path: file.path,
          size: file.size,
          exists: exists,
          isComplete: exists && stat.size == file.size && bad.isEmpty,
          verifiedBytes: verified,
          corruptedPieces: List.unmodifiable(bad),
        ),
      );
    }
    return Verification(pieces: List.unmodifiable(valid), files: List.unmodifiable(result));
  }

  @override
  String toString() => 'Metainfo($name, ${size.humanBytes}, ${files.length} files)';
}

/// The seconds since the epoch a [DateTime] can hold either side.
const _maxSeconds = 8640000000000;

/// [b], text in the charset [encoding] names (a torrent's `encoding` key), UTF-8 without one;
/// what does not decode becomes U+FFFD, never a list of numbers.
String _text(Uint8List b, String? encoding) {
  final label = encoding?.trim().toLowerCase();
  if (label == null || label.isEmpty || label == 'utf-8' || label == 'utf8') {
    return utf8.decode(b, allowMalformed: true);
  }
  return NativeBridge.main.decodeText(label, b);
}

/// What [Metainfo.verify] found: one flag per piece, and what that means per file.
///
/// {@category Formats}
final class Verification {
  /// Whether each piece is intact, by index.
  final List<bool> pieces;

  /// Each file's state, in torrent order.
  final List<FileVerification> files;

  const Verification({required this.pieces, required this.files});

  /// How many pieces are intact.
  int get intact => pieces.where((p) => p).length;

  /// Whether every piece and every file is intact (a torrent of no pieces is).
  bool get isComplete => intact == pieces.length && files.every((f) => f.isComplete);

  /// The intact share of the pieces, 0.0 to 1.0.
  double get ratio => pieces.isEmpty ? 1.0 : intact / pieces.length;

  @override
  String toString() => '$intact of ${pieces.length} pieces intact';
}

/// One file of a [Verification].
///
/// {@category Formats}
final class FileVerification {
  /// The file's path inside the torrent.
  final Path path;

  /// The size it should have.
  final int size;

  final bool exists;

  /// Whether it is there at its size with every piece it touches intact.
  final bool isComplete;

  /// The bytes of it in intact pieces.
  final int verifiedBytes;

  /// The pieces it touches that are missing or damaged.
  final List<int> corruptedPieces;

  const FileVerification({
    required this.path,
    required this.size,
    required this.exists,
    required this.isComplete,
    required this.verifiedBytes,
    required this.corruptedPieces,
  });

  @override
  String toString() =>
      '$path: ${isComplete
          ? 'complete'
          : exists
          ? 'incomplete ($verifiedBytes of $size bytes)'
          : 'missing'}';
}

/// About 256 MiB of pieces a native call: few hops, and progress that moves.
int _batchOf(int pieceLength) => (256 << 20) ~/ pieceLength < 1 ? 1 : (256 << 20) ~/ pieceLength;

/// The worker's call for [Metainfo.verify]: one byte per piece, 1 a match, checked a batch at
/// a time, reporting the bytes and stopping between batches. Top level, so it is sent only these.
Uint8List Function(NativeProgress, Pointer<Uint8>) _verifyCall(String files, int piece, Uint8List hashes, int total) =>
    (progress, stop) {
      final report = _reporter(progress);
      final count = hashes.length ~/ 20;
      final ok = Uint8List(count);
      final batch = _batchOf(piece);
      final out = NativeBridge.main.alloc(batch);
      try {
        for (var first = 0; first < count; first += batch) {
          // The caller's stop: it reads any failure then as its cancel.
          if (stop.value != 0) throw StateError('stopped');
          final n = count - first < batch ? count - first : batch;
          final code = NativeBridge.main.withText(
            files,
            (f, fl) => NativeBridge.main.withBytes(
              hashes,
              (h, hl) => _TorrentNative.verify(f, fl, piece, h, hl, first, n, out),
            ),
          );
          if (code < 0) throw NativeException('verify torrent pieces', NativeBridge.main.lastError());
          ok.setRange(first, first + n, out.asTypedList(n));
          final done = (first + n) * piece;
          report?.call(first + n, count, done < total ? done : total, total, nullptr, 0);
        }
        return ok;
      } finally {
        NativeBridge.main.free(out, batch);
      }
    };

/// [progress] callable from Dart, or `null` for none.
void Function(int, int, int, int, Pointer<Uint8>, int)? _reporter(NativeProgress progress) =>
    progress == nullptr ? null : progress.asFunction<void Function(int, int, int, int, Pointer<Uint8>, int)>();

/// Names a torrent leaves out of a folder: what operating systems put there on their own.
const _junk = ['.DS_Store', 'Thumbs.db', 'desktop.ini', '._*'];

Future<Metainfo> _create(
  Work work,
  Path root,
  List<Uri> trackers,
  int? pieceLength,
  String? name,
  bool private,
  String? comment,
) async {
  final type = await FileSystemEntity.type(root);
  if (type == FileSystemEntityType.notFound) {
    throw PathNotFoundException(root, const OSError('No such file or directory', 2), 'Cannot create a torrent of');
  }
  final single = type == FileSystemEntityType.file;
  final files = single
      ? [root]
      : (await root.files(only: '**', ignore: _junk).toList()
          ..sort());
  if (files.isEmpty) throw MissingException('a file', where: root);
  final sizes = [for (final f in files) (await FileStat.stat(f)).size];
  final total = sizes.fold(0, (a, b) => a + b);
  // About 1500 pieces, a power of two from 16 KiB to 16 MiB, as most clients choose.
  final piece = pieceLength ?? (1 << (total ~/ 1500).bitLength).clamp(16 << 10, 16 << 20);
  work.step('hashing');
  final hashes = await NativeBridge.main.run(
    work,
    _hashCall(jsonEncode([for (final f in files) File(f).absolute.path]), piece, total),
    onProgress: (r) => work.amount(r.bytes, total: r.bytesTotal),
  );
  final info = <String, Object>{
    'name': name ?? root.absolute.name,
    'piece length': piece,
    'pieces': hashes,
    if (single)
      'length': total
    else
      'files': [
        for (var i = 0; i < files.length; i++) {'length': sizes[i], 'path': files[i].relativeTo(root).segments},
      ],
    if (private) 'private': 1,
  };
  return Metainfo._decode(
    Bencode.encode({
      if (trackers.isNotEmpty) 'announce': '${trackers.first}',
      if (trackers.length > 1)
        'announce-list': [
          for (final t in trackers) ['$t'],
        ],
      'comment': ?comment,
      'created by': 'dart_toolkit',
      'creation date': Clock.current.now().millisecondsSinceEpoch ~/ 1000,
      'info': info,
    }),
  );
}

/// The worker's call for [Torrent.create]: every piece's SHA-1 of the files in [paths] (JSON),
/// a batch at a time, reporting the bytes and stopping between batches.
Uint8List Function(NativeProgress, Pointer<Uint8>) _hashCall(String paths, int piece, int total) => (progress, stop) {
  final report = _reporter(progress);
  final count = (total + piece - 1) ~/ piece;
  final batch = _batchOf(piece);
  final out = BytesBuilder(copy: false);
  for (var first = 0; first < count; first += batch) {
    // The caller's stop: it reads any failure then as its cancel.
    if (stop.value != 0) throw StateError('stopped');
    final n = count - first < batch ? count - first : batch;
    out.add(
      NativeBridge.main.withText(
        paths,
        (p, len) =>
            NativeBridge.main.take('hash torrent pieces', (o, l) => _TorrentNative.hash(p, len, piece, first, n, o, l)),
      ),
    );
    final done = (first + n) * piece;
    report?.call(first + n, count, done < total ? done : total, total, nullptr, 0);
  }
  return out.takeBytes();
};
