// The response cache of `Http.scope(cache:)`: a GET's `200` kept for as long as the scope
// says, in memory or in the scope's store. On disk, one file per URL and credential (a JSON
// line of URL, the URL that answered, credential, `Vary` values, headers and time, then the
// body), renamed into place
// whole, so a validator never pairs with another answer's bytes.

part of '../http.dart';

/// One kept answer.
final class _Kept {
  final String url;

  /// The URL that answered, after redirects: what a served answer's links resolve against.
  final String answered;

  /// The credentials and cookies it was asked with, hashed: one user's page is never another's.
  final String who;
  final Map<String, String?> vary;
  final Headers headers;
  final DateTime at;
  final int length;
  final Stream<List<int>> Function() body;

  const _Kept(this.url, this.answered, this.who, this.vary, this.headers, this.at, this.length, this.body);

  /// This with [headers], [at], [length] and [body] in place of its own.
  _Kept again(Headers headers, DateTime at, int length, Stream<List<int>> Function() body) =>
      _Kept(url, answered, who, vary, headers, at, length, body);

  /// Whether this answers [request] asked by [who], its `Vary` headers read as they go out:
  /// the request's own, else [defaults], the scope's.
  bool answers(Request request, String who, Headers defaults) =>
      url == '${request.url}' &&
      this.who == who &&
      vary.entries.every((e) => (request.headers[e.key] ?? defaults[e.key]) == e.value);
}

abstract class _Cache {
  _Cache();

  /// Memory caches by store: the process's when the scope has no store.
  static final _memory = <Store?, _MemoryCache>{};
  static final _folders = <String, _FolderCache>{};

  /// The cache [s] keeps answers in.
  static _Cache of(_Settings s) => switch (s.store) {
    final store? when store.folder != null => _folders.putIfAbsent(
      store.folder!,
      () => _FolderCache('${store.folder}${Platform.pathSeparator}cache'),
    ),
    final store => _memory.putIfAbsent(store, _MemoryCache.new),
  };

  static final _servedKey = Expando<bool>('cached');

  /// Whether [res] was answered from the cache, with no body sent by the server.
  static bool served(StreamedResponse res) => _servedKey[res] == true;

  /// A plain GET: not a download or range ([_literal]), nor already conditional.
  static bool wants(Request request) =>
      request.method == 'GET' &&
      !_literal(request) &&
      !request.headers.containsKey('if-none-match') &&
      !request.headers.containsKey('if-modified-since');

  /// Headers about the bytes on the wire, not the kept body: a `304`'s are not taken.
  static const _bodyless = {'content-length', 'content-encoding', 'transfer-encoding', 'content-range', 'set-cookie'};

  Future<_Kept?> load(String key);

  /// [body] passed through, kept under [key] with [kept]'s description once read to its end.
  Stream<List<int>> keep(String key, _Kept kept, Stream<List<int>> body);

  /// [kept] again, with [headers] and a new time.
  Future<void> refresh(String key, _Kept kept, Headers headers);

  /// [request] through [send], or answered here: an answer younger than [fresh] with no request,
  /// an older one asked for conditionally, a `304` served from here as the `200` it stands for.
  /// [defaults] are the scope's headers, which the request goes out with where it has none.
  /// [request] is left as it is: a retry sends it again through here.
  Future<StreamedResponse> through(
    Request request, {
    required String who,
    required Duration fresh,
    required Headers defaults,
    required Future<StreamedResponse> Function(Request request) send,
  }) async {
    final hashed = _hash(who);
    final key = _hash('${request.url}\n$hashed');
    var stored = await load(key);
    if (stored != null && !stored.answers(request, hashed, defaults)) stored = null;
    if (stored != null && Clock.current.now().difference(stored.at) < fresh) return _serve(stored, request);
    var asked = request;
    if (stored != null) {
      final tag = stored.headers['etag'];
      final date = stored.headers['last-modified'];
      if (tag != null || date != null) {
        asked = request.copy();
        if (tag != null) asked.headers['if-none-match'] = tag;
        if (date != null) asked.headers['if-modified-since'] = date;
      }
    }
    final res = await send(asked);
    if (res.statusCode == 304 && stored != null) {
      unawaited(_drain(res));
      // A 304 carries the headers that changed (RFC 9111 §4.3.4): they replace what is kept.
      final headers = Headers(stored.headers);
      res.headers.forEach((k, v) {
        if (!_bodyless.contains(k)) headers[k] = v;
      });
      await refresh(key, stored, headers);
      final again = await load(key) ?? stored;
      return _serve(again, request, res.url);
    }
    final varies = res.headers['vary']?.split(',').map((h) => h.trim().toLowerCase()).where((h) => h.isNotEmpty);
    if (res.statusCode != 200 ||
        (res.headers['cache-control'] ?? '').toLowerCase().contains('no-store') ||
        (varies?.contains('*') ?? false)) {
      return res;
    }
    final kept = _Kept(
      '${request.url}',
      '${res.url ?? request.url}',
      hashed,
      {for (final h in varies ?? const <String>[]) h: request.headers[h] ?? defaults[h]},
      Headers(res.headers)..remove('set-cookie'),
      Clock.current.now(),
      0,
      Stream.empty,
    );
    return MessageInternals.carrying(res, keep(key, kept, res.stream));
  }

  /// [kept]'s body as the `200` it was, answering [request] from [url].
  StreamedResponse _serve(_Kept kept, Request request, [Uri? url]) {
    final res = StreamedResponse(
      kept.body(),
      200,
      contentLength: kept.length,
      headers: Headers(kept.headers),
      request: request,
      url: url ?? Uri.parse(kept.answered),
      reasonPhrase: 'OK',
    );
    _servedKey[res] = true;
    return res;
  }

  /// FNV-1a of [text], in hex: a credential is never kept as it is.
  static String _hash(String text) {
    var hash = 0xcbf29ce484222325;
    for (final unit in text.codeUnits) {
      hash = (hash ^ unit) * 0x100000001b3;
    }
    return '${(hash >>> 32).toRadixString(16).padLeft(8, '0')}${(hash & 0xffffffff).toRadixString(16).padLeft(8, '0')}';
  }
}

/// Answers in this process, the least recently kept dropped past [_cap] bytes.
final class _MemoryCache extends _Cache {
  static const _cap = 64 << 20;
  final _entries = <String, (_Kept, Uint8List)>{};
  var _bytes = 0;

  @override
  Future<_Kept?> load(String key) async {
    final entry = _entries[key];
    if (entry == null) return null;
    final (kept, body) = entry;
    return kept.again(kept.headers, kept.at, body.length, () => Stream.value(body));
  }

  /// Past [_cap] the body is passed through and nothing more held: a 5 GB stream read under
  /// `cache:` is never in memory.
  @override
  Stream<List<int>> keep(String key, _Kept kept, Stream<List<int>> body) async* {
    BytesBuilder? out = BytesBuilder(copy: false);
    await for (final chunk in body) {
      if (out != null && out.length + chunk.length > _cap) out = null;
      out?.add(chunk);
      yield chunk;
    }
    if (out != null) _put(key, kept, out.takeBytes());
  }

  @override
  Future<void> refresh(String key, _Kept kept, Headers headers) async {
    final entry = _entries[key];
    if (entry == null) return;
    _put(key, kept.again(headers, Clock.current.now(), 0, Stream.empty), entry.$2);
  }

  void _put(String key, _Kept kept, Uint8List body) {
    if (_entries.remove(key) case (_, final old)) _bytes -= old.length;
    if (body.length > _cap) return;
    _entries[key] = (kept, body);
    _bytes += body.length;
    while (_bytes > _cap && _entries.isNotEmpty) {
      final first = _entries.keys.first;
      _bytes -= _entries.remove(first)!.$2.length;
    }
  }
}

/// Answers in a folder of the scope's store, one file each.
final class _FolderCache extends _Cache {
  final String dir;

  _FolderCache(this.dir);

  File _file(String key) => File('$dir${Platform.pathSeparator}$key');

  @override
  Future<_Kept?> load(String key) async {
    final file = _file(key);
    RandomAccessFile? raf;
    try {
      raf = await file.open();
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
          found = true;
          break;
        }
      }
      final length = await raf.length();
      await raf.close();
      raf = null;
      if (!found) return null;
      final meta = jsonDecode(utf8.decode(head)) as Map<String, Object?>;
      final offset = head.length + 1;
      final url = meta['url']! as String;
      return _Kept(
        url,
        meta['answered'] as String? ?? url,
        meta['who']! as String,
        (meta['vary'] as Map?)?.cast<String, String?>() ?? const {},
        Headers((meta['headers']! as Map).cast<String, String>()),
        DateTime.fromMillisecondsSinceEpoch(meta['at']! as int, isUtc: true),
        length - offset,
        () => file.openRead(offset),
      );
    } on Object catch (_) {
      // Missing, half-written by another version, or unreadable: as good as not kept.
      if (raf != null) unawaited(raf.close().catchError((Object _) {})); // best-effort: closing a read handle
      return null;
    }
  }

  static List<int> _meta(_Kept kept, Headers headers, DateTime at) => utf8.encode(
    '${jsonEncode({'url': kept.url, 'answered': kept.answered, 'who': kept.who, 'vary': kept.vary, 'headers': Map.of(headers), 'at': at.millisecondsSinceEpoch})}\n',
  );

  @override
  Stream<List<int>> keep(String key, _Kept kept, Stream<List<int>> body) async* {
    final file = _file(key);
    final part = File('${file.path}.${FileBridge.token()}.part');
    IOSink? sink;
    var whole = false;
    try {
      await part.parent.create(recursive: true);
      sink = part.openWrite()..add(_meta(kept, kept.headers, kept.at));
      await for (final chunk in body) {
        sink.add(chunk);
        yield chunk;
      }
      whole = true;
    } finally {
      await sink?.close();
      if (whole) {
        await FileBridge.rename(part, file.path);
      } else {
        await _discard(part);
      }
    }
  }

  @override
  Future<void> refresh(String key, _Kept kept, Headers headers) async {
    final file = _file(key);
    final offset = (await file.length()) - kept.length;
    final part = File('${file.path}.${FileBridge.token()}.part');
    final sink = part.openWrite()..add(_meta(kept, headers, Clock.current.now()));
    try {
      await sink.addStream(file.openRead(offset));
      await sink.close();
      await FileBridge.rename(part, file.path);
    } catch (_) {
      await sink.close().catchError((Object _) {}); // best-effort: the part is discarded next
      await _discard(part);
      rethrow;
    }
  }
}

Future<void> _discard(File file) async {
  try {
    if (await file.exists()) await file.delete();
  } on FileSystemException catch (_) {} // best-effort: nothing to discard
}
