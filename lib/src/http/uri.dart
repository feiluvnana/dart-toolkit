part of '../http.dart';

/// A colon before any `/`, `?` or `#`, not starting `://`: an href would read it as a scheme.
final _schemeLike = RegExp(r'^[^/?#:]+:(?!//)');

/// Addresses: joining, naming, querying, and server-sent events.
///
/// {@category Networking}
extension UriExtensions on Uri {
  /// Resolves [part] as an href under this path: `'https://x.com/api'.url / 'users'` is
  /// `https://x.com/api/users`. So `?` in [part] starts a query and `#` a fragment, and an
  /// absolute or `..` [part] goes where it points; a `projects:batchGet` stays a segment. A
  /// file name that may hold `?` or `#` goes through `Uri.encodeComponent` first.
  Uri operator /(String part) {
    final dir = path.endsWith('/') ? this : replace(path: '$path/');
    // Appended, not resolved: a relative `./a:b` would come back as `a%3Ab`.
    return _schemeLike.hasMatch(part) ? Uri.parse('${_withoutQuery(dir.removeFragment())}$part') : dir.resolve(part);
  }

  /// The last non-empty path segment, decoded, as `Path.name`: `song.mp3` for
  /// `…/tracks/song.mp3?x=1`, `tracks` for `…/tracks/`, `''` for a bare host.
  ///
  /// Always one file name safe on every OS, since the server chooses it: a separator, `:`,
  /// a control or bidi character becomes `_`, a Windows device name gains a `_`, trailing dots
  /// and spaces go, and it is cut to 255 UTF-8 bytes keeping its extension. `..` is `''`.
  String get name => MessageInternals.safeName(pathSegments.lastWhere((s) => s.isNotEmpty, orElse: () => ''));

  /// This URI with [params] added to its query; a `null` value removes the parameter:
  /// `url.withQuery({'page': 2, 'q': 'dart'})`.
  Uri withQuery(Map<String, Object?> params) {
    final all = {...queryParametersAll};
    params.forEach((k, v) => v == null ? all.remove(k) : all[k] = v is Iterable ? [for (final x in v) '$x'] : ['$v']);
    return all.isEmpty ? _withoutQuery(this) : replace(queryParameters: all);
  }

  /// What this URI streams, an event at a time: server-sent events (read as the HTML
  /// standard does), or else one event per non-empty line — NDJSON, a log. [json] makes it a
  /// POST, as a streaming API is asked.
  ///
  /// ```dart
  /// await for (final e in api.events(json: {'stream': true, 'prompt': 'hi'})) {
  ///   stdout.write(e.data.json['text'].to<String>());
  /// }
  /// ```
  ///
  /// A non-2xx throws a [StatusException] holding the first 64 KiB of the error body; stopping
  /// the loop closes the connection. The scope's settings are those where it was called; its
  /// timeout bounds the headers only, so a quiet stream is never cut.
  ///
  /// With [reconnect], an event stream that ends or breaks off is asked for again — after the
  /// server's last `retry:` (3 s until it sends one), with the last `id:` as `Last-Event-ID` —
  /// until the loop stops, the enclosing [Cancel.scope] is cancelled, or the server answers
  /// `204` (done) or another status (a [StatusException]). The first connection failing
  /// throws, as without it. A stream of lines is never asked for twice.
  Stream<ServerEvent> events({Map<String, String>? headers, Object? json, bool reconnect = false}) =>
      _events(_settings, this, headers: headers, json: json, reconnect: reconnect);
}

/// Where [_events] stands between connections: the last `id:` and the server's `retry:`.
final class _EventState {
  String? id;
  Duration retry = const Duration(seconds: 3);

  /// Whether the last connection was an event stream, so may be asked for again.
  bool stream = false;
}

/// [UriExtensions.events] with [s].
Stream<ServerEvent> _events(
  _Settings s,
  Uri url, {
  Map<String, String>? headers,
  Object? json,
  required bool reconnect,
}) {
  if (!reconnect) return _connection(s, url, headers: headers, json: json, state: _EventState());
  final state = _EventState();
  late final StreamController<ServerEvent> out;
  StreamSubscription<ServerEvent>? current;
  Timer? waiting;
  var stopped = false;
  // Whether an event stream was ever answered: before that, a failure is the caller's to see.
  var established = false;
  void Function()? unhear;

  void stop() {
    stopped = true;
    waiting?.cancel();
    unhear?.call();
  }

  void finish([Object? error, StackTrace? st]) {
    stop();
    if (out.isClosed) return;
    if (error != null) out.addError(error, st);
    out.close();
  }

  late final void Function() connect;
  void again() {
    if (stopped) return;
    waiting = Timer(state.retry, connect);
  }

  connect = () {
    if (stopped) return;
    if (Cancel.token case final token? when token.isCancelled) return finish(CancelledException.of(token));
    current = _connection(s, url, headers: headers, json: json, state: state).listen(
      out.add,
      onError: (Object e, StackTrace st) {
        current = null;
        // Refused by status, or never connected at all: the server or the URL is wrong.
        if (e is StatusException || !_transient(e) || !(established |= state.stream)) return finish(e, st);
        again();
      },
      onDone: () {
        current = null;
        established |= state.stream;
        state.stream ? again() : finish();
      },
      cancelOnError: true,
    );
  };

  out = StreamController<ServerEvent>(
    onListen: () {
      final token = Cancel.token;
      unhear = token?.onCancel(() {
        final cut = current;
        current = null;
        finish(CancelledException.of(token));
        unawaited(cut?.cancel().catchError((Object _) {})); // the send it cuts short: the cancel is reported
      });
      connect();
    },
    onPause: () => current?.pause(),
    onResume: () => current?.resume(),
    onCancel: () {
      stop();
      final cut = current;
      current = null;
      return cut?.cancel().catchError((Object _) {}); // a send cut short by the leaving listener
    },
  );
  return out.stream;
}

/// One connection of [_events]: its events, the last `id:` and `retry:` kept in [state]. A `204`
/// ends it with nothing, and [state] no longer a stream.
Stream<ServerEvent> _connection(
  _Settings s,
  Uri url, {
  required Map<String, String>? headers,
  required Object? json,
  required _EventState state,
}) async* {
  final request = Request(json == null ? 'GET' : 'POST', url, headers: headers, json: json);
  request.headers.putIfAbsent('accept', () => 'text/event-stream');
  if (state.id case final id? when id.isNotEmpty) request.headers['last-event-id'] = id;
  state.stream = false;
  // Never through the scope's cache: a live stream is not an answer to keep or replay.
  final res = await _chain(s, request, idle: false);
  {
    if (res.statusCode == 204) {
      unawaited(_drain(res));
      return;
    }
    if (!res.isOk) {
      // An API says why in the body; a stream's error page is small, and cut if not.
      final body = await _readCapped(res, cap: 64 * 1024, url: url, cut: true);
      throw StatusException(
        Response.bytes(
          body,
          res.statusCode,
          headers: res.headers,
          request: request,
          url: res.url,
          reasonPhrase: res.reasonPhrase,
        ),
      );
    }
    final lines = res.stream.transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter());
    if (!(res.headers['content-type'] ?? '').toLowerCase().startsWith('text/event-stream')) {
      await for (final line in lines) {
        if (line.trim().isNotEmpty) yield (event: 'message', data: line, id: null);
      }
      return;
    }
    state.stream = true;
    var event = 'message';
    final data = StringBuffer();
    var pending = false;
    await for (final line in lines) {
      if (line.isEmpty) {
        if (pending) yield (event: event, data: data.toString(), id: state.id);
        event = 'message';
        data.clear();
        pending = false;
        continue;
      }
      if (line.startsWith(':')) continue;
      final colon = line.indexOf(':');
      final field = colon == -1 ? line : line.substring(0, colon);
      var value = colon == -1 ? '' : line.substring(colon + 1);
      if (value.startsWith(' ')) value = value.substring(1);
      switch (field) {
        case 'data':
          if (pending) data.write('\n');
          data.write(value);
          pending = true;
        case 'event':
          event = value.isEmpty ? 'message' : value;
        case 'id' when !value.contains('\u0000'):
          state.id = value;
        case 'retry' when _digits.hasMatch(value):
          state.retry = Duration(milliseconds: int.parse(value));
      }
    }
    // An event cut off by the end is dropped, as a browser does.
  }
}

final _digits = RegExp(r'^[0-9]+$');

/// [url] without its query string, its fragment kept.
Uri _withoutQuery(Uri url) {
  if (!url.hasQuery) return url;
  final s = '$url';
  final q = s.indexOf('?');
  final f = s.indexOf('#', q);
  return Uri.parse(s.substring(0, q) + (f < 0 ? '' : s.substring(f)));
}

/// One event of [UriExtensions.events]: its name, its data, and the last `id` the stream
/// gave. A line of NDJSON is a `message` whose data is the line.
///
/// {@category Networking}
typedef ServerEvent = ({String event, String data, String? id});

/// Text as an address.
///
/// {@category Networking}
extension StringUrl on String {
  /// This text as a [Uri], as `Uri.parse` reads it.
  Uri get url => Uri.parse(this);
}
