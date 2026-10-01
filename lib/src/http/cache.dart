// The conditional-GET cache of `Http.scope(cache:)`: one file per URL — a JSON line of URL
// and headers, then the body — renamed into place whole, so a validator never pairs with
// another answer's bytes.

part of '../../http.dart';

final class _Cache {
  final Path dir;

  _Cache(this.dir);

  /// [request] through [send], conditional when an answer is stored; a `304` is served from
  /// disk.
  Future<StreamedResponse> through(Request request, Future<StreamedResponse> Function(Request) send) async {
    if (!_wants(request)) return send(request);
    final file = File('${dir.path}${Platform.pathSeparator}${_key(request.url)}');
    final stored = await _load(file, request.url);
    if (stored != null) {
      if (stored.headers['etag'] case final tag?) request.headers['if-none-match'] = tag;
      if (stored.headers['last-modified'] case final date?) request.headers['if-modified-since'] = date;
    }
    final res = await send(request);
    if (res.statusCode == 304 && stored != null) {
      unawaited(_drain(res));
      final raf = stored.raf;
      final length = await raf.length() - stored.offset;
      await raf.setPosition(stored.offset);
      return StreamedResponse(
        _streamRaf(raf, length),
        200,
        contentLength: length,
        headers: stored.headers,
        request: request,
        url: res.url,
        reasonPhrase: 'OK',
      );
    }
    if (stored != null) unawaited(stored.raf.close().catchError((Object _) {}));
    final headers = res.headers;
    if (res.statusCode != 200 ||
        !(headers.containsKey('etag') || headers.containsKey('last-modified')) ||
        (headers['cache-control'] ?? '').toLowerCase().contains('no-store')) {
      return res;
    }
    return res._carrying(_keep(res.stream, file, request.url, headers));
  }

  /// A plain GET: not a download or range ([_literal]), nor already conditional.
  static bool _wants(Request request) =>
      request.method == 'GET' &&
      !_literal(request) &&
      !request.headers.containsKey('if-none-match') &&
      !request.headers.containsKey('if-modified-since');

  /// The stored answer for [url] in [file], or `null` — also when it is a colliding URL's.
  static Future<({Headers headers, int offset, RandomAccessFile raf})?> _load(File file, Uri url) async {
    RandomAccessFile? raf;
    try {
      raf = await file.open(mode: FileMode.read);
      final head = <int>[];
      var found = false;
      while (head.length < 1 << 20) {
        final chunk = await raf.read(2048);
        if (chunk.isEmpty) break;
        final end = chunk.indexOf(0x0a);
        if (end == -1) {
          head.addAll(chunk);
        } else {
          head.addAll(chunk.take(end));
          await raf.setPosition(head.length + 1);
          found = true;
          break;
        }
      }
      if (!found) {
        await raf.close();
        return null;
      }
      final meta = jsonDecode(utf8.decode(head)) as Map<String, Object?>;
      if (meta['url'] != '$url') {
        await raf.close();
        return null;
      }
      return (headers: Headers((meta['headers'] as Map).cast<String, String>()), offset: head.length + 1, raf: raf);
    } catch (_) {
      if (raf != null) unawaited(raf.close().catchError((Object _) {}));
      return null;
    }
  }

  static Stream<List<int>> _streamRaf(RandomAccessFile raf, int remaining) async* {
    try {
      var left = remaining;
      while (left > 0) {
        final toRead = left < 64 * 1024 ? left : 64 * 1024;
        final chunk = await raf.read(toRead);
        if (chunk.isEmpty) break;
        left -= chunk.length;
        yield chunk;
      }
    } finally {
      await raf.close();
    }
  }

  /// [body], written to [file] as it is read, and kept only when read to its end.
  static Stream<List<int>> _keep(Stream<List<int>> body, File file, Uri url, Headers headers) async* {
    final part = File('${file.path}.${Secure.token(6)}.part');
    IOSink? sink;
    var whole = false;
    try {
      await part.parent.create(recursive: true);
      // A `set-cookie` must not be answered twice.
      final kept = Map.of(headers)..remove('set-cookie');
      sink = part.openWrite()..add(utf8.encode('${jsonEncode({'url': '$url', 'headers': kept})}\n'));
      await for (final chunk in body) {
        sink.add(chunk);
        yield chunk;
      }
      whole = true;
    } finally {
      await sink?.close();
      if (whole) {
        await part.rename(file.path);
      } else {
        await _discard(part);
      }
    }
  }

  /// FNV-1a of [url], in hex.
  static String _key(Uri url) {
    var hash = 0xcbf29ce484222325;
    for (final unit in url.toString().codeUnits) {
      hash = (hash ^ unit) * 0x100000001b3;
    }
    return '${(hash >>> 32).toRadixString(16).padLeft(8, '0')}${(hash & 0xffffffff).toRadixString(16).padLeft(8, '0')}';
  }
}
