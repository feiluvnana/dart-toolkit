part of '../archive.dart';

// ---------------------------------------------------------------------------
// In-house streaming tar. Headers are 512 bytes; file data follows, padded
// to a 512 multiple; the archive ends at the first all-zero block (a clean
// EOF there counts too). Pax extended headers (`x`, and global `g`) and GNU
// long names and link names (`L`, `K`) override the header's; pax `mtime`
// overrides its seconds. Symlinks and hardlinks come out as headers for
// [un.placeLinks].
// ---------------------------------------------------------------------------

/// AppleDouble magic: `00 05 16 07`.
bool _isAppleDouble(List<int> b) => b.length >= 4 && b[0] == 0 && b[1] == 5 && b[2] == 0x16 && b[3] == 7;

/// Tar typeflags we write and read.
const _tarFile = 0x30; // '0'
const _tarSymlink = 0x32; // '2'
const _tarDir = 0x35; // '5'

/// What [_parseTar] emits: a member header, its body in chunks (files
/// only), then the end of the member.
sealed class _TarEvent {}

final class _TarHeader extends _TarEvent {
  _TarHeader(this.name, this.mode, this.mtime, this.kind, [this.link = '']);
  final String name;
  final int mode;
  final DateTime? mtime;
  final un.Kind kind;

  /// A link's target.
  final String link;
}

final class _TarBody extends _TarEvent {
  _TarBody(this.bytes);
  final Uint8List bytes;
}

final class _TarEnd extends _TarEvent {}

/// Header chunks for one member: an optional pax extended header when the
/// name needs more than ustar's split `prefix/name` can hold (or a [link]
/// target more than 100 bytes), then the 512-byte header itself.
List<List<int>> _tarHeader({
  required String name,
  required int size,
  required int mode,
  required DateTime mtime,
  required int typeflag,
  String link = '',
}) {
  final out = <List<int>>[];
  final records = <int>[];
  var headerName = name;
  var prefix = '';
  if (utf8.encode(name).length > 100) {
    final isDir = name.endsWith('/');
    final core = isDir ? name.substring(0, name.length - 1) : name;
    final slash = core.lastIndexOf('/');
    final tail = slash < 0 ? core : core.substring(slash + 1);
    final head = slash < 0 ? '' : core.substring(0, slash);
    final tailBytes = utf8.encode(isDir ? '$tail/' : tail).length;
    if (slash > 0 && tailBytes <= 100 && utf8.encode(head).length <= 155) {
      headerName = isDir ? '$tail/' : tail;
      prefix = head;
    } else {
      // A pax `path=` record carries the full name; the following header
      // carries a truncated one for readers without pax support.
      records.addAll(_paxRecord('path', name));
      headerName = _truncateUtf8(name, 100);
    }
  }
  if (utf8.encode(link).length > 100) records.addAll(_paxRecord('linkpath', link));
  if (records.isNotEmpty) {
    final padded = Uint8List((records.length + 511) ~/ 512 * 512);
    padded.setRange(0, records.length, records);
    out.add(
      _rawHeader(
        name: '././@PaxHeader',
        size: records.length,
        mode: 0,
        mtime: mtime,
        typeflag: 0x78, // 'x'
      ),
    );
    out.add(padded);
  }
  out.add(
    _rawHeader(
      name: headerName,
      size: size,
      mode: mode,
      mtime: mtime,
      typeflag: typeflag,
      prefix: prefix,
      link: _truncateUtf8(link, 100),
    ),
  );
  return out;
}

List<int> _rawHeader({
  required String name,
  required int size,
  required int mode,
  required DateTime mtime,
  required int typeflag,
  String prefix = '',
  String link = '',
}) {
  final buf = Uint8List(512);
  _writeField(buf, 0, 100, utf8.encode(name));
  _writeOctal(buf, 100, 8, mode & 0xFFF);
  _writeOctal(buf, 108, 8, 0);
  _writeOctal(buf, 116, 8, 0);
  if (size > 0x1FFFFFFFF) {
    // 8 GiB and up: GNU base-256 (top bit set, big-endian value).
    buf[124] = 0x80;
    for (var i = 0; i < 8; i++) {
      buf[135 - i] = (size >> (8 * i)) & 0xFF;
    }
  } else {
    _writeOctal(buf, 124, 12, size);
  }
  final secs = mtime.millisecondsSinceEpoch ~/ 1000;
  _writeOctal(buf, 136, 12, secs < 0 ? 0 : secs);
  buf[156] = typeflag;
  _writeField(buf, 157, 100, utf8.encode(link));
  buf.setRange(257, 263, 'ustar\x00'.codeUnits);
  buf[263] = 0x30; // '00'
  buf[264] = 0x30;
  _writeField(buf, 345, 155, utf8.encode(prefix));
  // The checksum covers the header with its own field read as spaces.
  var sum = 0;
  for (var i = 0; i < 512; i++) {
    sum += (i >= 148 && i < 156) ? 0x20 : buf[i];
  }
  _writeOctal(buf, 148, 8, sum, trailingSpace: true);
  return buf;
}

/// Raw bytes into a fixed field, truncated when too long (a 100-byte name
/// has no NUL terminator, which ustar allows).
void _writeField(List<int> buf, int offset, int length, List<int> bytes) {
  final n = bytes.length > length ? length : bytes.length;
  buf.setRange(offset, offset + n, bytes);
}

/// Zero-padded octal digits with a trailing NUL (`length` includes it); the
/// checksum field instead ends NUL + space.
void _writeOctal(List<int> buf, int offset, int length, int value, {bool trailingSpace = false}) {
  final width = trailingSpace ? length - 2 : length - 1;
  var digits = value.toRadixString(8);
  if (digits.length > width) digits = digits.substring(digits.length - width);
  for (var i = 0; i < width - digits.length; i++) {
    buf[offset + i] = 0x30;
  }
  for (var i = 0; i < digits.length; i++) {
    buf[offset + width - digits.length + i] = digits.codeUnitAt(i);
  }
  buf[offset + width] = 0;
  if (trailingSpace) buf[offset + width + 1] = 0x20;
}

/// One pax record: `<len> <key>=<value>\n`, where `<len>` counts itself.
List<int> _paxRecord(String key, String value) {
  final body = utf8.encode('$key=$value\n');
  var n = body.length + 2;
  while (true) {
    final head = utf8.encode('$n ');
    if (head.length + body.length == n) return [...head, ...body];
    n = head.length + body.length;
  }
}

/// Truncate to fit [maxBytes] UTF-8 bytes without splitting a character.
String _truncateUtf8(String s, int maxBytes) {
  if (utf8.encode(s).length <= maxBytes) return s;
  var end = s.length;
  while (end > 0 && utf8.encode(s.substring(0, end)).length > maxBytes) {
    end--;
  }
  return s.substring(0, end);
}

/// Largest pax / GNU long-name record accepted (they are buffered).
const _tarMetaMax = 1 << 20;

/// Streams tar events: file bytes are forwarded as they arrive (O(1) memory,
/// whatever the member size); only the 512-byte header and pax/GNU records
/// are buffered. A zero block or a clean EOF ends the archive; a partial
/// header or body at EOF or a bad checksum is a [ContentException]. When
/// [input] came out of a [container] (gzip, xz) that opens with no tar
/// header, the error says so.
Stream<_TarEvent> _parseTar(Stream<List<int>> input, {String? container}) async* {
  final head = BytesBuilder(copy: false);
  final metaBuf = BytesBuilder(copy: false);
  final meta = _TarMeta();
  var remaining = 0; // body bytes still to come
  var pad = 0; // padding bytes still to skip
  var metaFlag = 0; // typeflag of the pax/GNU record being collected, else 0
  var emit = false; // forward the current body as events
  var seen = 0; // members yielded so far

  Never fail(String message, {bool notTar = false}) {
    // Data that decodes but opens with a bad header is not a tar at all.
    if (notTar && container != null && seen == 0) {
      throw ContentException('corrupt archive: $container data is not a tar archive');
    }
    throw ContentException(message);
  }

  void finishMeta() {
    meta.read(metaFlag, metaBuf.takeBytes());
    metaFlag = 0;
  }

  // After the end marker the rest is read and dropped, not cancelled: a
  // gzip trailer (or a hash checking at end of stream) runs only at EOF, so
  // a truncated .tar.gz fails instead of extracting.
  var ended = false;
  await for (final raw in input) {
    if (ended) continue;
    final c = raw is Uint8List ? raw : Uint8List.fromList(raw);
    var i = 0;
    while (i < c.length) {
      if (remaining > 0) {
        final n = remaining < c.length - i ? remaining : c.length - i;
        final piece = Uint8List.sublistView(c, i, i + n);
        i += n;
        remaining -= n;
        if (metaFlag != 0) {
          metaBuf.add(piece);
        } else if (emit) {
          yield _TarBody(piece);
        }
        if (remaining == 0) {
          if (metaFlag != 0) {
            finishMeta();
          } else if (emit) {
            yield _TarEnd();
          }
        }
        continue;
      }
      if (pad > 0) {
        final n = pad < c.length - i ? pad : c.length - i;
        i += n;
        pad -= n;
        continue;
      }
      final need = 512 - head.length;
      final n = need < c.length - i ? need : c.length - i;
      head.add(Uint8List.sublistView(c, i, i + n));
      i += n;
      if (head.length < 512) continue;
      final h = head.takeBytes();
      if (h.every((b) => b == 0)) {
        ended = true;
        break;
      }
      if (!_tarChecksumOk(h, 0)) {
        fail('corrupt archive: bad tar header', notTar: true);
      }
      var size = _tarSize(h, 0);
      if (size < 0) {
        fail('corrupt archive: bad tar size in header', notTar: true);
      }
      final typeflag = h[156];
      final isMeta = typeflag == 0x78 || typeflag == 0x67 || typeflag == 0x4c || typeflag == 0x4b;
      if (!isMeta) size = meta.takeSize() ?? size;
      pad = (512 - size % 512) % 512;
      remaining = size;
      if (isMeta) {
        if (size > _tarMetaMax) {
          fail('corrupt archive: tar record too large', notTar: true);
        }
        metaFlag = typeflag;
        emit = false;
        if (size == 0 && metaFlag != 0) finishMeta();
        continue;
      }
      final member = _tarMember(h, typeflag, meta);
      seen++;
      emit = member.kind == un.Kind.file; // a link's data, if any, is skipped
      yield member;
      if (emit && size == 0) yield _TarEnd();
    }
  }
  if (!ended && (head.length != 0 || remaining != 0 || pad != 0)) {
    fail('corrupt archive: truncated tar', notTar: true);
  }
}

/// The member that tar header [h] (of [typeflag]) opens, with [meta]'s
/// overrides applied and cleared. Another type is a [ContentException].
_TarHeader _tarMember(Uint8List h, int typeflag, _TarMeta meta) {
  var name = _tarString(h, 0, 100);
  final prefix = _tarString(h, 345, 155);
  if (prefix.isNotEmpty) name = '$prefix/$name';
  name = meta.path ?? meta.globalPath ?? name;
  final link = meta.link ?? _tarString(h, 157, 100);
  final secs = _tarOctal(h, 136, 12);
  final mtime = meta.mtime ?? (secs > 0 ? DateTime.fromMillisecondsSinceEpoch(secs * 1000) : null);
  meta.path = meta.link = meta.mtime = null;
  // Old (V7) tars mark a folder with a regular type and a trailing '/';
  // '7' (contiguous file) is a regular file everywhere but on old
  // Masscomp systems.
  final regular = typeflag == 0x30 || typeflag == 0 || typeflag == 0x37;
  if (typeflag == 0x35 || regular && name.endsWith('/')) return _TarHeader(name, _tarMode(h), mtime, un.Kind.dir);
  if (regular) return _TarHeader(name, _tarMode(h), mtime, un.Kind.file);
  if (typeflag == 0x31 || typeflag == 0x32) {
    return _TarHeader(name, _tarMode(h), mtime, typeflag == 0x31 ? un.Kind.hardlink : un.Kind.symlink, link);
  }
  throw ContentException("corrupt archive: unsupported tar entry '${String.fromCharCode(typeflag)}' for $name");
}

/// What pax and GNU records say about the next member, or (pax `g`)
/// every following one.
final class _TarMeta {
  String? path; // pax `x` / GNU `L`: the next entry's name
  String? globalPath; // pax `g`: every following entry's name
  String? link; // pax `linkpath` / GNU `K`: the next entry's link target
  int? _size; // pax `size`: the next entry's size
  DateTime? mtime; // pax `mtime`: the next entry's time

  /// The pax size override, once.
  int? takeSize() {
    final s = _size;
    _size = null;
    return s;
  }

  /// Take in a record of [flag] (`x`, `g`, `L` or `K`) holding [data].
  void read(int flag, Uint8List data) {
    if (flag == 0x78 || flag == 0x67) {
      // Pax extended ('x') or global ('g') header: `path=` renames,
      // `linkpath=` is a link's target, `mtime=` (seconds, maybe
      // fractional) its time.
      final records = _parsePax(data);
      if (records.keys.any((k) => k.startsWith('GNU.sparse.'))) {
        throw ContentException('sparse tar member unsupported: ${records['GNU.sparse.name'] ?? records['path']}');
      }
      final renamed = records['path'];
      final named = renamed != null && renamed.isNotEmpty;
      if (flag == 0x67) {
        if (named) globalPath = renamed;
        return;
      }
      if (named) path = renamed;
      final linkpath = records['linkpath'];
      if (linkpath != null && linkpath.isNotEmpty) link = linkpath;
      final secs = double.tryParse(records['mtime'] ?? '');
      if (secs != null && secs.isFinite && secs.abs() < 8e12) {
        mtime = DateTime.fromMillisecondsSinceEpoch((secs * 1000).round());
      }
      final sz = int.tryParse(records['size'] ?? '');
      if (sz != null && sz >= 0) _size = sz;
    } else if (flag == 0x4c || flag == 0x4b) {
      // GNU long name or link name: the data is the next entry's.
      var text = utf8.decode(data, allowMalformed: true);
      while (text.endsWith('\x00')) {
        text = text.substring(0, text.length - 1);
      }
      if (text.isEmpty) return;
      if (flag == 0x4c) {
        path = text;
      } else {
        link = text;
      }
    }
  }
}

/// NUL-terminated string field, malformed UTF-8 replaced.
String _tarString(List<int> buf, int offset, int length) {
  var end = offset;
  while (end < offset + length && buf[end] != 0) {
    end++;
  }
  return utf8.decode(buf.sublist(offset, end), allowMalformed: true);
}

/// The mode field; a damaged one is no mode (the umask default), never the
/// 0777 that -1 & 0x1FF would give.
int _tarMode(List<int> h) {
  final m = _tarOctal(h, 100, 8);
  return m < 0 ? 0 : m;
}

/// Octal field (NUL/space padded); empty means 0 for mode/mtime.
int _tarOctal(List<int> buf, int offset, int length) {
  var value = 0;
  var digits = 0;
  for (var i = offset; i < offset + length; i++) {
    final b = buf[i];
    if (b == 0 || b == 0x20) continue;
    if (b < 0x30 || b > 0x37) return -1;
    value = value * 8 + (b - 0x30);
    digits++;
  }
  return digits == 0 ? 0 : value;
}

/// Size field: octal, or base-256 when the top bit is set. -1 when invalid.
int _tarSize(List<int> buf, int header) {
  const off = 124;
  if (buf[header + off] & 0x80 != 0) {
    var value = 0;
    for (var i = header + off + 1; i < header + off + 12; i++) {
      value = value * 256 + buf[i];
    }
    return value;
  }
  var value = 0;
  var digits = 0;
  for (var i = header + off; i < header + off + 12; i++) {
    final b = buf[i];
    if (b == 0 || b == 0x20) continue;
    if (b < 0x30 || b > 0x37) return -1;
    value = value * 8 + (b - 0x30);
    digits++;
  }
  return digits == 0 ? -1 : value;
}

/// The classic tar sniff, also the read-side validator: the octal value in
/// bytes 148..156 equals the sum of the 512 header bytes with the checksum
/// field itself read as spaces.
bool _tarChecksumOk(List<int> bytes, int offset) {
  if (bytes.length < offset + 512) return false;
  var stored = 0;
  var digits = 0;
  for (var i = offset + 148; i < offset + 156; i++) {
    final b = bytes[i];
    if (b == 0 || b == 0x20) continue;
    if (b < 0x30 || b > 0x37) return false;
    stored = stored * 8 + (b - 0x30);
    digits++;
  }
  if (digits == 0) return false;
  var sum = 0;
  for (var i = offset; i < offset + 512; i++) {
    sum += (i >= offset + 148 && i < offset + 156) ? 0x20 : bytes[i];
  }
  return sum == stored;
}

Map<String, String> _parsePax(Uint8List data) {
  final out = <String, String>{};
  var i = 0;
  while (i < data.length) {
    final space = data.indexOf(0x20, i);
    if (space < 0) break;
    final len = int.tryParse(utf8.decode(data.sublist(i, space)));
    if (len == null || len <= 0 || i + len > data.length) break;
    var record = utf8.decode(data.sublist(space + 1, i + len), allowMalformed: true);
    if (record.endsWith('\n')) record = record.substring(0, record.length - 1);
    final eq = record.indexOf('=');
    if (eq > 0) out[record.substring(0, eq)] = record.substring(eq + 1);
    i += len;
  }
  return out;
}
