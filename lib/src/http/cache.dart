// The conditional-GET cache `Http.scope(cache:)` keeps.
//
// One file per URL: a line of JSON — the URL and the headers of the `200` — then the body.
// A single file is renamed into place whole, so a reader never pairs one answer's validator
// with another answer's bytes. Nothing here is public; `cache:` is the whole vocabulary.

part of '../../http.dart';

final class _Cache {
  final Path dir;

  _Cache(this.dir);

  /// [request] through [send], asked conditionally when an answer is stored, and a `304`
  /// answered from disk.
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
      final length = await file.length() - stored.offset;
      return StreamedResponse(
        file.openRead(stored.offset),
        200,
        contentLength: length,
        headers: stored.headers,
        request: request,
        url: res.url,
        reasonPhrase: 'OK',
      );
    }
    final headers = res.headers;
    if (res.statusCode != 200 ||
        !(headers.containsKey('etag') || headers.containsKey('last-modified')) ||
        (headers['cache-control'] ?? '').toLowerCase().contains('no-store')) {
      return res;
    }
    return res._carrying(_keep(res.stream, file, request.url, headers));
  }

  /// A plain GET: the cache has no business with a download (its own `ifModified` does this
  /// for a file), a range, or a request that already asks conditionally.
  static bool _wants(Request request) =>
      request.method == 'GET' &&
      !_literal(request) &&
      !request.headers.containsKey('if-none-match') &&
      !request.headers.containsKey('if-modified-since');

  /// The stored answer for [url] in [file], or `null` when there is none or it is another
  /// URL's — two URLs whose names collide never serve each other.
  static Future<({Headers headers, int offset})?> _load(File file, Uri url) async {
    try {
      final head = <int>[];
      await for (final chunk in file.openRead()) {
        final end = chunk.indexOf(0x0a);
        if (end == -1) {
          head.addAll(chunk);
          if (head.length > 1 << 20) return null;
          continue;
        }
        head.addAll(chunk.take(end));
        break;
      }
      final meta = jsonDecode(utf8.decode(head)) as Map<String, Object?>;
      if (meta['url'] != '$url') return null;
      return (headers: Headers((meta['headers'] as Map).cast<String, String>()), offset: head.length + 1);
    } catch (_) {
      return null; // not there, or not ours: fetch it
    }
  }

  /// [body], written to [file] as it is read, and renamed into place only when it is read to
  /// its end — an answer cut off, or one the caller stopped reading, is not kept.
  static Stream<List<int>> _keep(Stream<List<int>> body, File file, Uri url, Headers headers) async* {
    final part = File('${file.path}.${Secure.token(6)}.part');
    IOSink? sink;
    var whole = false;
    try {
      await part.parent.create(recursive: true);
      // A `set-cookie` is the one header that must not be answered twice.
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

  /// A file name for [url]: FNV-1a over its text, in hex.
  static String _key(Uri url) {
    var hash = 0xcbf29ce484222325;
    for (final unit in utf8.encode('$url')) {
      hash = (hash ^ unit) * 0x100000001b3;
    }
    return '${(hash >>> 32).toRadixString(16).padLeft(8, '0')}${(hash & 0xffffffff).toRadixString(16).padLeft(8, '0')}';
  }
}
