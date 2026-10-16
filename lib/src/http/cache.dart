// cache: GET answers stored in a folder.
part of '../../http.dart';

/// One GET's place under a cache folder: `<key>.body` plus `<key>.json`
/// (URL, status, headers, the request headers the answer varies on, time).
/// Everything is fixed when the request is made: the key (URL and every
/// secret header given: `authorization`, `cookie`, `x-api-key` …), checked
/// again on read with the URL and a second hash, and the jar's cookies,
/// which must match the stored ones except those the answer set itself, so
/// a session cookie the server rotates on every answer still hits.
final class _Cache {
  _Cache(this._dir, Uri uri, Map<String, String> sent, _Client client)
    : _sent = {for (final e in sent.entries) e.key.toLowerCase(): e.value},
      _request = 'GET $uri',
      _jar = jar.headerFor(client._s.cookies, uri) ?? '' {
    final who = [
      for (final k in _sent.keys.toList()..sort())
        if (names.isSecretHeader(k)) '$k: ${_sent[k]}',
    ].join('\n');
    final bytes = utf8.encode('$_request\n$who');
    _key = '$_dir/${_fnv(bytes, 0xcbf29ce484222325)}';
    _who = _fnv(bytes, 0x84222325cbf29ce4);
  }

  /// FNV-1a over [bytes] from [basis], as 16 hex digits.
  static String _fnv(List<int> bytes, int basis) {
    var h = basis;
    for (final c in bytes) {
      h = ((h ^ c) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    return h.toUnsigned(64).toRadixString(16).padLeft(16, '0');
  }

  final String _dir;
  final Map<String, String> _sent;
  final String _request;
  final String _jar;
  late final String _key;
  late final String _who;

  /// A `Cookie` header without the cookies named in [names].
  static String _strip(String header, List<String> names) => [
    for (final pair in header.split('; '))
      if (pair.isNotEmpty && !names.contains(pair.split('=').first)) pair,
  ].join('; ');

  /// The stored answer, fresh or not, when its `Vary` headers match.
  Future<_Entry?> read() async {
    try {
      final meta = jsonDecode(await File('$_key.json').readAsString()) as Map<String, Object?>;
      // Another request that hashed to this name is a miss, never its body.
      if (meta['request'] != _request || meta['who'] != _who) return null;
      final vary = (meta['vary'] as Map).cast<String, Object?>();
      if (vary.entries.any((e) => _sent[e.key] != e.value)) return null;
      final set = (meta['set'] as List).cast<String>();
      if (_strip(_jar, set) != meta['jar']) return null; // another session's page
      if (!await File('$_key.body').exists()) return null;
      return _Entry(
        '$_key.body',
        meta['url'] as String,
        meta['status'] as int,
        (meta['headers'] as Map).cast<String, String>(),
        vary,
        DateTime.fromMillisecondsSinceEpoch(meta['time'] as int),
        set,
      );
    } on IOException {
      return null;
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  /// Store a 200 [res], streamed to disk (never whole in memory), and
  /// answer from the stored copy.
  Future<Response> write(Response res, _Client client) async {
    final headers = <String, String>{};
    res._resp?.headers.forEach((name, values) {
      // The jar has the cookies (a file must not); the body on disk is
      // decoded, so the wire's encoding and length no longer describe it.
      if (!const {'set-cookie', 'content-encoding', 'content-length', 'transfer-encoding'}.contains(name)) {
        headers[name] = values.join(', ');
      }
    });
    final vary = {
      for (final name in (headers['vary'] ?? '').split(',').map((s) => s.trim().toLowerCase()))
        if (name.isNotEmpty && name != '*') name: _sent[name],
    };
    if (!await Directory(_dir).exists()) {
      await Directory(_dir).create(recursive: true);
      await posix.chmod(_dir, 0x1c0); // 0700: bodies of authenticated pages live here
    }
    final tmp = File('$_key.${DateTime.now().microsecondsSinceEpoch}.tmp');
    try {
      await res.stream().pipe(tmp.openWrite());
      headers['content-length'] = '${await tmp.length()}';
      await tmp.rename('$_key.body');
    } catch (_) {
      if (await tmp.exists()) await tmp.delete();
      rethrow;
    }
    final set = [
      for (final raw in res._resp?.headers['set-cookie'] ?? const <String>[])
        if (jar.parseSetCookie(raw) case final c?) c.name,
    ];
    final entry = _Entry('$_key.body', res.url(), res.status(), headers, vary, DateTime.now(), set);
    await _save(entry);
    return entry.response(client, res._method);
  }

  /// A 304 for a stale [entry]: the stored body stands, with the 304's
  /// headers laid over it and a new time.
  Future<_Entry> refresh(_Entry entry, Response res) async {
    final headers = {...entry.headers};
    res._resp?.headers.forEach((name, values) {
      if (!const {'set-cookie', 'content-encoding', 'content-length', 'transfer-encoding'}.contains(name)) {
        headers[name] = values.join(', ');
      }
    });
    final fresh = _Entry(entry.body, entry.url, entry.status, headers, entry.vary, DateTime.now(), entry.set);
    await _save(fresh);
    return fresh;
  }

  Future<void> _save(_Entry e) async {
    final tmp = File('$_key.${DateTime.now().microsecondsSinceEpoch}.json.tmp');
    await tmp.writeAsString(
      jsonEncode({
        'request': _request,
        'who': _who,
        'url': e.url,
        'status': e.status,
        'headers': e.headers,
        'vary': e.vary,
        'time': e.time.millisecondsSinceEpoch,
        'set': e.set,
        'jar': _strip(_jar, e.set),
      }),
    );
    await tmp.rename('$_key.json');
  }
}

/// A stored answer: its body file and what was said about it.
final class _Entry {
  _Entry(this.body, this.url, this.status, this.headers, this.vary, this.time, this.set);

  final String body, url;
  final int status;
  final Map<String, String> headers;
  final Map<String, Object?> vary;
  final DateTime time;

  /// The cookie names the answer set: they may differ on the next request.
  final List<String> set;

  bool fresh(Duration ttl) => DateTime.now().difference(time) <= ttl;

  Response response(_Client client, String method) => Response._stored(client, method, url, status, headers, body);
}
