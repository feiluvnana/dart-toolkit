// cache: GET answers stored in a folder.
part of '../../http.dart';

/// GET answers stored under a folder: `<key>.body` plus `<key>.json`
/// (URL, status, headers, the request headers the answer varies on, time).
final class _Cache {
  _Cache(this._dir);

  final String _dir;

  /// The entry for [uri] as these credentials see it: a page fetched
  /// with one user's token or cookies is never served to another.
  String _key(Uri uri, Map<String, String> sent, _Client client) {
    final lower = {for (final e in sent.entries) e.key.toLowerCase(): e.value};
    final who =
        '${lower['authorization'] ?? ''}\n${lower['cookie'] ?? ''}\n${jar.headerFor(client._s.cookies, uri) ?? ''}';
    var h = 0xcbf29ce484222325;
    for (final c in utf8.encode('GET $uri\n$who')) {
      h = ((h ^ c) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    return '$_dir/${h.toUnsigned(64).toRadixString(16).padLeft(16, '0')}';
  }

  Future<Response?> read(Uri uri, Map<String, String> sent, Duration ttl, _Client client, String method) async {
    final key = _key(uri, sent, client);
    try {
      final meta = jsonDecode(await File('$key.json').readAsString()) as Map<String, Object?>;
      final time = DateTime.fromMillisecondsSinceEpoch(meta['time'] as int);
      if (DateTime.now().difference(time) > ttl) return null;
      final vary = (meta['vary'] as Map).cast<String, Object?>();
      final lower = {for (final e in sent.entries) e.key.toLowerCase(): e.value};
      if (vary.entries.any((e) => lower[e.key] != e.value)) return null;
      final bytes = await File('$key.body').readAsBytes();
      return Response._cached(
        client,
        method,
        meta['url'] as String,
        meta['status'] as int,
        (meta['headers'] as Map).cast<String, String>(),
        bytes,
      );
    } on IOException {
      return null;
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  Future<Response> write(Uri uri, Map<String, String> sent, Response res, _Client client) async {
    final bytes = Uint8List.fromList(await res.bytes());
    final headers = <String, String>{};
    res._resp?.headers.forEach((name, values) {
      if (name != 'set-cookie') headers[name] = values.join(', '); // the jar has them; a file must not
    });
    final lower = {for (final e in sent.entries) e.key.toLowerCase(): e.value};
    final vary = {
      for (final name in (headers['vary'] ?? '').split(',').map((s) => s.trim().toLowerCase()))
        if (name.isNotEmpty && name != '*') name: lower[name],
    };
    final key = _key(uri, sent, client);
    if (!await Directory(_dir).exists()) {
      await Directory(_dir).create(recursive: true);
      await posix.chmod(_dir, 0x1c0); // 0700: bodies of authenticated pages live here
    }
    await File('$key.body').writeAsBytes(bytes);
    await File('$key.json').writeAsString(
      jsonEncode({
        'url': res.url(),
        'status': res.status(),
        'headers': headers,
        'vary': vary,
        'time': DateTime.now().millisecondsSinceEpoch,
      }),
    );
    return Response._cached(client, res._method, res.url(), res.status(), headers, bytes);
  }
}
