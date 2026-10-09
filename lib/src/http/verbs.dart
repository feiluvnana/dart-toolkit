part of '../http.dart';

/// HTTP requests on [Uri]: each a [Task] of the [Response], strict when awaited.
///
/// {@category Networking}
extension UriVerbs on Uri {
  /// GET. Awaited, the [Response] of a 2xx, else a [StatusException] holding the response; a
  /// failure to answer is a [ClientException], running out of time a [TimeoutException].
  ///
  /// ```dart
  /// final res  = await url.get();                  // a 2xx, or it throws
  /// final page = await url.get().html;             // an Html
  /// final ok   = await url.head().isOk;            // never throws for a status
  /// await for (final chunk in url.get().stream) { … }   // the body as it arrives
  /// ```
  Task<Response> get({Map<String, String>? headers}) => Request('GET', this, headers: headers).send();

  /// HEAD: the headers without the body.
  Task<Response> head({Map<String, String>? headers}) => Request('HEAD', this, headers: headers).send();

  /// POST, with at most one of [text], [bytes], [form] (url-encoded), [json], [files] or [file]
  /// and its `content-type`. [files] is `multipart/form-data` streamed off disk; with [form] it
  /// sends fields and files together. [file] streams one file as the body.
  ///
  /// ```dart
  /// await api.post(json: {'name': 'x'});
  /// await api.post(form: {'title': 'holiday'}, files: {'photo': 'beach.jpg'});
  /// await presigned.put(file: 'backup.tar.zst');
  /// ```
  Task<Response> post({
    Map<String, String>? headers,
    String? text,
    List<int>? bytes,
    Map<String, Object?>? form,
    Object? json,
    Map<String, String>? files,
    String? file,
  }) => _verb('POST', this, headers, text, bytes, form, json, files, file);

  /// PUT; see [post] for the body.
  Task<Response> put({
    Map<String, String>? headers,
    String? text,
    List<int>? bytes,
    Map<String, Object?>? form,
    Object? json,
    Map<String, String>? files,
    String? file,
  }) => _verb('PUT', this, headers, text, bytes, form, json, files, file);

  /// PATCH; see [post] for the body.
  Task<Response> patch({
    Map<String, String>? headers,
    String? text,
    List<int>? bytes,
    Map<String, Object?>? form,
    Object? json,
    Map<String, String>? files,
    String? file,
  }) => _verb('PATCH', this, headers, text, bytes, form, json, files, file);

  /// DELETE; see [post] for the body.
  Task<Response> delete({
    Map<String, String>? headers,
    String? text,
    List<int>? bytes,
    Map<String, Object?>? form,
    Object? json,
    Map<String, String>? files,
    String? file,
  }) => _verb('DELETE', this, headers, text, bytes, form, json, files, file);
}

/// The verbs with a body, one way.
Task<Response> _verb(
  String method,
  Uri url,
  Map<String, String>? headers,
  String? text,
  List<int>? bytes,
  Map<String, Object?>? form,
  Object? json,
  Map<String, String>? files,
  String? file,
) => Request(
  method,
  url,
  headers: headers,
  text: text,
  bytes: bytes,
  form: form,
  json: json,
  files: files,
  file: file,
).send();

/// Sending a [Request] as it is: a form's `submission`, a method the verbs do not name.
///
/// {@category Networking}
extension RequestSend on Request {
  /// Sends this request with the enclosing [Http.scope]'s settings, as the verbs do. The request
  /// is copied first, so sending it twice sends it twice; [Response.request] is the copy that
  /// went out.
  Task<Response> send() => _send(this);
}

/// A request in flight, read without buffering or without throwing.
///
/// {@category Networking}
extension TaskResponse on Task<Response> {
  /// Whether the answer is a 2xx: `false` for any other status, never a throw for one. A request
  /// that fails to answer still throws.
  Future<bool> get isOk => settled.then(
    (status) => switch (status) {
      Done() => true,
      Failed(error: StatusException()) => false,
      Failed(:final error, :final stackTrace) => Error.throwWithStackTrace(error, stackTrace),
      Stopped(:final reason) => throw CancelledException(reason),
      _ => false,
    },
  );

  /// The body as it arrives, never held whole (5 GB is fine), once the answer is a 2xx; any
  /// other status is a [StatusException] on the stream. Leaving the stream cancels the request.
  /// Read it right away: once the body is being buffered, this is the buffered body.
  Stream<List<int>> get stream {
    final exchange = _exchanges[this];
    if (exchange == null || exchange.buffering) return Stream.fromFuture(then((res) => res.bytes));
    exchange.streaming = true;
    final out = exchange.out;
    out.onCancel = () => cancel('the stream was left');
    unawaited(
      settled.then((status) {
        if (out.isClosed) return;
        switch (status) {
          case Failed(:final error, :final stackTrace) when !exchange.piped:
            out.addError(error, stackTrace);
          case Stopped(:final reason) when !exchange.piped:
            out.addError(CancelledException(reason));
          case _:
        }
        out.close();
      }),
    );
    return out.stream;
  }
}

/// The body of a request in flight, read once its answer is a 2xx.
///
/// {@category Networking}
extension ResponseFuture on Future<Response> {
  /// The body decoded as text, once the response is a 2xx; any other status is a
  /// [StatusException]. See [Response.text].
  Future<String> get text => then((res) => res.isOk ? res.text : throw StatusException(res));

  /// The body as it arrived, once the response is a 2xx; any other status is a
  /// [StatusException].
  Future<Uint8List> get bytes => then((res) => res.isOk ? res.bytes : throw StatusException(res));
}

/// How a request's body is read: streamed to [out] when asked before the answer came, else
/// buffered.
final class _Streaming {
  var streaming = false;
  var buffering = false;
  var piped = false;
  late final out = StreamController<List<int>>();
}

final _exchanges = Expando<_Streaming>('exchange');

/// How a status names a URL: its host and path.
String _label(Uri url) => '${url.host}${url.path.isEmpty ? '/' : url.path}';

/// How often a transfer reports its amount: an event per few-KB chunk costs allocations nobody
/// could see, at a frame rate.
const _reportEvery = Duration(milliseconds: 50);

/// [request] as a task, with the settings where it was made.
Task<Response> _send(Request request) {
  final s = _settings;
  final how = _Streaming();
  final task = TaskInternals.start(request.url, _label(request.url), (work) async {
    final sent = request.copy();
    final (head, whole) = await _retrying(s, sent, () async {
      final res = await _exchange(s, sent, step: work.step);
      if (!res.isOk) throw await _refused(res, sent);
      if (_Cache.served(res)) TaskInternals.stale(work);
      // Asked for as a stream: the retries end at the headers.
      if (how.streaming) return (res, null);
      how.buffering = true;
      final total = res.contentLength;
      var reported = Clock.current.elapsed;
      final bytes = await MessageInternals.collect(
        res.stream,
        total,
        onChunk: (received) {
          final now = Clock.current.elapsed;
          if (now - reported < _reportEvery) return;
          reported = now;
          work.amount(received, total: total);
        },
      );
      return (
        null,
        Response.bytes(
          bytes,
          res.statusCode,
          headers: res.headers,
          request: sent,
          url: res.url,
          reasonPhrase: res.reasonPhrase,
        ),
      );
    }, step: work.step);
    if (whole != null) return whole;
    final res = head!;
    final total = res.contentLength;
    var received = 0;
    how.piped = true;
    (Object, StackTrace)? broke;
    await how.out.addStream(
      res.stream
          .map((chunk) {
            received += chunk.length;
            work.amount(received, total: total);
            return chunk;
          })
          .handleError((Object e, StackTrace st) {
            broke ??= (e, st);
            Error.throwWithStackTrace(e, st);
          }),
      cancelOnError: true,
    );
    // Heard by the stream already; the task ends with it too.
    if (broke case (final e, final st)) Error.throwWithStackTrace(e, st);
    return Response.bytes(
      const [],
      res.statusCode,
      headers: res.headers,
      request: sent,
      url: res.url,
      reasonPhrase: res.reasonPhrase,
    );
  });
  _exchanges[task] = how;
  return task;
}
