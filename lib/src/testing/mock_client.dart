part of '../../testing.dart';

/// A [Client] whose responses come from a handler.
///
/// ```dart
/// final client = MockClient((request) async => Response('ok', 200));
/// await Http.session(() => url.get(), client: client);
/// ```
///
/// {@category Networking}
final class MockClient implements Client {
  final Future<StreamedResponse> Function(Request request, Stream<List<int>> body) _handler;

  /// Answers every request with the [Response] the [handler] returns.
  MockClient(Future<Response> Function(Request request) handler)
    : _handler = ((request, _) async {
        final res = await handler(request);
        return StreamedResponse(
          Stream.value(res.bytes),
          res.statusCode,
          contentLength: res.bytes.length,
          headers: res.headers,
          request: request,
          url: res.url ?? request.url,
          reasonPhrase: res.reasonPhrase,
          isRedirect: res.isRedirect,
        );
      });

  /// Answers with a [StreamedResponse], for bodies that arrive in pieces.
  MockClient.streaming(this._handler);

  @override
  Future<StreamedResponse> send(Request request) => _handler(request, Stream.value(Uint8List.fromList(request.bytes)));

  @override
  void close() {}
}
