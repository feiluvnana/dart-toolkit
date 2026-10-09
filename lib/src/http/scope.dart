part of '../http.dart';

const _settingsKey = #dartToolkitHttp;

/// The settings of the enclosing [Http.scope], else the defaults: read when a request is made,
/// so a task, a download or a stream made inside a scope keeps its settings wherever it runs.
_Settings get _settings => Zone.current[_settingsKey] as _Settings? ?? _Settings.root;

/// How long a request waits for its headers, and for each chunk of its body.
const _defaultTimeout = Duration(seconds: 30);

/// The longest `Retry-After` waited out when the policy names no `max`; a longer one is the
/// answer, not a pause.
const _longestRetryAfter = Duration(seconds: 30);

/// The ambient HTTP settings: no request takes a `client:`; a scope names one, with its timeout,
/// headers, credentials, cookies, cache, retries and per-host limits, for every request,
/// download, crawl and render inside it.
///
/// {@category Networking}
abstract final class Http {
  /// Runs [body] with these settings for every request inside it; an inner scope inherits what it
  /// does not set. Requests outside any scope get the same defaults: [Retry.network], a cookie
  /// session (one per process), and 30 s for the headers and for each chunk of a body. A scope
  /// only changes settings; it never turns behaviour on.
  ///
  /// ```dart
  /// await Http.scope(() async { … },
  ///   timeout: 1.m, headers: {'user-agent': 'me/1'},
  ///   credentials: {'https://api.example.com': Secret('Bearer $token')},
  ///   retry: Retry(5), perHost: 4, delay: 500.ms, store: app / 'http', cache: 1.d,
  ///   client: await Chrome.launch());
  /// ```
  ///
  /// - [client]: what sends: a `Chrome`, [Client.fake], `IoClient(proxies: …)`. The library
  ///   never closes a client it was given.
  /// - [timeout]: how long a request waits for its headers, and then for each chunk of its body
  ///   ([TimeoutException]); a browser's wait for a tab or a challenge does not count.
  /// - [headers]: what a request does not set itself, names compared ignoring case. A credential
  ///   (`authorization`, `cookie`, `proxy-authorization`) is an [ArgumentError] here: it goes in
  ///   [credentials] or [cookies], bound to where it may go.
  /// - [credentials]: an origin (`https://api.example.com`) to the `authorization` its requests
  ///   carry; never sent anywhere else, a redirect to another origin included.
  /// - [cookies]: the session's jar: what it holds is sent where it belongs, and what responses
  ///   set (on every redirect hop) is kept in it.
  /// - [store]: where the session's cookies are kept between runs (loaded on entry, saved when the
  ///   body's result has finished), and the [cache] when one is set.
  /// - [cache]: a GET answered `200` is kept this long and served without a request; older, it is
  ///   asked for again, conditionally when it named an `ETag` or `Last-Modified`, and a `304`
  ///   serves it. An answer is one user's: it is keyed by the credentials and cookies sent and
  ///   its `Vary` headers. A served answer is `Done(fresh: false)`.
  /// - [retry]: how a request is tried again: a transport failure, a timeout, a `408`, a `5xx`
  ///   (not `501`/`505`), a `429` or `503` (after its `Retry-After`, up to the policy's `max`,
  ///   else 30 s; longer is the answer). A `POST` or `PATCH` is sent again only on a `429`/`503`
  ///   with `Retry-After`: the server saying it did nothing. Each retry is a `Warned`.
  /// - [perHost], [delay]: at most [perHost] requests to one host at once, each [delay] after
  ///   the last (jittered ±25 %), for every request: verbs, downloads, crawls, renders. An inner
  ///   scope's limits apply on top of an outer one's.
  ///
  /// The scope lasts until [body]'s result has finished: a `Task`, a `Batch` and a `Future` are
  /// awaited. Every wait and request in flight stops when the enclosing [Cancel.scope] does.
  static Future<T> scope<T>(
    FutureOr<T> Function() body, {
    Client? client,
    Duration? timeout,
    Map<String, String>? headers,
    Map<String, Secret>? credentials,
    CookieJar? cookies,
    Store? store,
    Duration? cache,
    Retry? retry,
    int? perHost,
    Duration? delay,
  }) async {
    _positive(timeout, 'timeout');
    _positive(cache, 'cache');
    _positive(delay, 'delay');
    if (perHost != null && perHost < 1) {
      throw ArgumentError.value(perHost, 'perHost', 'Invalid perHost, expected at least 1');
    }
    for (final name in headers?.keys ?? const <String>[]) {
      if (HttpBridge.credentials.contains(name.toLowerCase())) {
        throw ArgumentError.value(
          name,
          'headers',
          'Invalid header $name: a credential goes in credentials: or cookies:',
        );
      }
    }
    final bound = {for (final MapEntry(:key, :value) in (credentials ?? const {}).entries) _originKey(key): value};
    _charsets();
    final outer = _settings;
    final jar = cookies ?? (store == null ? outer.jar : CookieJar());
    if (store != null) await _loadSession(store, jar);
    final settings = _Settings(
      client: client ?? outer.client,
      timeout: timeout ?? outer.timeout,
      headers: Headers({...outer.headers, ...?headers}),
      credentials: bound.isEmpty ? outer.credentials : {...outer.credentials, ...bound},
      jar: jar,
      store: store ?? outer.store,
      cache: cache ?? outer.cache,
      retry: retry ?? outer.retry,
      limits: perHost == null && delay == null ? outer.limits : [...outer.limits, _Limit(perHost, delay)],
    );
    try {
      return await runZoned(() async => await body(), zoneValues: {_settingsKey: settings});
    } finally {
      if (store != null) await _saveSession(store, jar);
    }
  }
}

void _positive(Duration? value, String name) {
  if (value != null && value <= Duration.zero) {
    throw ArgumentError.value(value, name, 'Invalid $name, expected more than zero');
  }
}

/// What a request is sent with: one scope's settings, merged with every scope around it.
final class _Settings {
  /// The scope's client, or `null` for the shared [IoClient].
  final Client? client;
  final Duration timeout;
  final Headers headers;

  /// By [_originKey].
  final Map<String, Secret> credentials;
  final CookieJar jar;
  final Store? store;
  final Duration? cache;
  final Retry retry;

  /// Every scope's per-host limits, outermost first.
  final List<_Limit> limits;

  const _Settings({
    required this.client,
    required this.timeout,
    required this.headers,
    required this.credentials,
    required this.jar,
    required this.store,
    required this.cache,
    required this.retry,
    required this.limits,
  });

  /// Outside any scope: the same defaults as inside one.
  static final root = _Settings(
    client: null,
    timeout: _defaultTimeout,
    headers: Headers(),
    credentials: const {},
    jar: CookieJar(),
    store: null,
    cache: null,
    retry: Retry.network,
    limits: const [],
  );

  /// The `authorization` bound to [url]'s origin, if any.
  Secret? credentialFor(Uri url) => credentials.isEmpty ? null : credentials[_origin(url)];

  /// How many requests to one host the limits allow together, or `null` for no limit.
  int? get perHost => limits.map((l) => l.perHost).nonNulls.fold<int?>(null, (a, b) => a == null || b < a ? b : a);
}

/// [url]'s origin, `scheme://host:port`, the port spelled even when it is the default.
String _origin(Uri url) => '${url.scheme}://${url.host.toLowerCase()}:${url.port}';

/// A `credentials:` key as the origin it names; anything but an http(s) origin is an
/// [ArgumentError].
String _originKey(String key) {
  final url = Uri.tryParse(key);
  if (url == null || (url.scheme != 'http' && url.scheme != 'https') || url.host.isEmpty) {
    throw ArgumentError.value(key, 'credentials', 'Invalid origin, expected https://host[:port]');
  }
  if (url.path.isNotEmpty && url.path != '/' || url.hasQuery || url.hasFragment) {
    throw ArgumentError.value(key, 'credentials', 'Invalid origin, expected no path, query or fragment');
  }
  return _origin(url);
}

/// Where a session's cookies live in its store.
const _cookiesKey = Key<List<Map<String, Object?>>>('cookies', or: []);

Future<void> _loadSession(Store store, CookieJar jar) async {
  final saved = await store.read(_cookiesKey);
  if (saved.isEmpty) return;
  final stored = CookieJar.fromJson(saved);
  // What the jar was handed beats what was kept.
  for (final cookie in stored) {
    if (!jar._cookies.any((c) => CookieJar._same(c, cookie))) jar.add(cookie);
  }
}

Future<void> _saveSession(Store store, CookieJar jar) => store.write(_cookiesKey, jar.toJson());

/// One scope's `perHost` and `delay`, kept per host: a permit while a request is out, and the
/// time the next one may start.
final class _Limit {
  final int? perHost;
  final Duration? delay;
  final _hosts = <String, _HostTurns>{};

  _Limit(this.perHost, this.delay);

  /// Waits for [url]'s host to have room and to be due, books the next slot, and answers the
  /// release of the permit. [waiting] is told when it has to wait.
  Future<void Function()> enter(Uri url, {void Function()? waiting}) async {
    final host = _hosts.putIfAbsent(_hostKey(url), _HostTurns.new);
    if (perHost case final most?) {
      if (host.active >= most) {
        waiting?.call();
        await host.turn();
      } else {
        host.active++;
      }
    }
    var released = false;
    void release() {
      if (released || perHost == null) return;
      released = true;
      host.leave();
    }

    try {
      if (delay case final gap?) {
        final now = Clock.current.now();
        final booked = host.next;
        final at = booked == null || booked.isBefore(now) ? now : booked;
        host.next = at.add(gap.jittered());
        if (at.isAfter(now)) {
          waiting?.call();
          await at.difference(now).delay();
        }
      }
    } catch (_) {
      release();
      rethrow;
    }
    return release;
  }

  /// Runs [hear] whenever a permit for [url]'s host frees and nobody is queued for it; returns
  /// the function that stops it.
  void Function() onRoom(Uri url, void Function() hear) {
    final host = _hosts.putIfAbsent(_hostKey(url), _HostTurns.new);
    host._room.add(hear);
    return () => host._room.remove(hear);
  }

  /// How long until [url]'s host is due and has room, `Duration.zero` when it is now: so a
  /// crawl hands it a page only then.
  Duration dueIn(Uri url) {
    final host = _hosts[_hostKey(url)];
    if (host == null) return Duration.zero;
    // Full: a long wait, cut short by [onRoom] when a permit frees.
    if (perHost case final most? when host.active >= most) return const Duration(seconds: 1);
    final next = host.next;
    if (next == null) return Duration.zero;
    final wait = next.difference(Clock.current.now());
    return wait.isNegative ? Duration.zero : wait;
  }
}

/// [url]'s host as the limits key it: scheme, host and port.
String _hostKey(Uri url) => _origin(url);

final class _HostTurns {
  int active = 0;
  DateTime? next;
  final _queue = Queue<Completer<void>>();

  /// Waits for a permit; a cancel of the enclosing scope while waiting takes none.
  Future<void> turn() {
    final token = Cancel.token;
    final mine = Completer<void>();
    _queue.add(mine);
    final unhear = token?.onCancel(() {
      if (_queue.remove(mine)) mine.completeError(CancelledException.of(token));
    });
    return mine.future.whenComplete(() => unhear?.call());
  }

  void leave() {
    if (_queue.isNotEmpty) {
      _queue.removeFirst().complete();
    } else {
      active--;
      // A crawl that holds its pages back while the host is full hears the room at once.
      for (final hear in [..._room]) {
        hear();
      }
    }
  }

  /// Who to tell when a permit frees with nobody waiting for it.
  final _room = <void Function()>{};
}
