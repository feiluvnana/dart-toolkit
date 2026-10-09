// SOCKS5 (RFC 1928) for `IoClient(proxies: ['socks5://…'])`, with RFC 1929's user and password:
// `dart:io` speaks only HTTP proxies, so the tunnel is opened here and handed to `HttpClient`
// as its connection.

part of '../http.dart';

/// Connections for [url] through the SOCKS5 [proxy], the name resolved by the proxy; an https
/// [url] is secured end to end inside the tunnel.
Future<ConnectionTask<Socket>> _socksConnect(Uri url, Uri proxy, {required bool unsafe}) async {
  final task = await Socket.startConnect(proxy.host, proxy.port);
  Future<Socket> open() async {
    final socket = await task.socket;
    try {
      final tunnel = await _socksHandshake(socket, url, proxy);
      if (url.scheme != 'https') return tunnel;
      return await SecureSocket.secure(socket, host: url.host, onBadCertificate: unsafe ? (_) => true : null);
    } catch (_) {
      socket.destroy();
      rethrow;
    }
  }

  return ConnectionTask.fromSocket(open(), task.cancel);
}

/// The SOCKS5 greeting, login and `CONNECT` on [socket]. Answers a socket reading on after the
/// reply; for https the raw [socket] is secured instead, its subscription paused here.
Future<Socket> _socksHandshake(Socket socket, Uri url, Uri proxy) async {
  final reader = _ByteReader(socket);
  try {
    final login = HttpBridge.login(proxy);
    socket.add(login == null ? const [5, 1, 0] : const [5, 2, 0, 2]);
    final [_, method] = await reader.take(2);
    if (method == 2 && login != null) {
      final (user, password) = login;
      final name = utf8.encode(user);
      final pass = utf8.encode(password.reveal);
      socket.add([1, name.length, ...name, pass.length, ...pass]);
      if ((await reader.take(2))[1] != 0) {
        throw SocketException('SOCKS proxy refused the login for $user', address: _address(proxy));
      }
    } else if (method != 0) {
      throw SocketException('SOCKS proxy accepts no method offered (${login == null ? 'no login' : 'login'})');
    }
    final port = url.hasPort ? url.port : (url.scheme == 'https' ? 443 : 80);
    final ip = InternetAddress.tryParse(url.host);
    final host = utf8.encode(url.host);
    socket.add([
      5, 1, 0, //
      if (ip == null) ...[
        3,
        host.length,
        ...host,
      ] else ...[
        ip.type == InternetAddressType.IPv6 ? 4 : 1,
        ...ip.rawAddress,
      ],
      port >> 8, port & 0xff,
    ]);
    final [_, reply, _, kind] = await reader.take(4);
    await reader.take(
      switch (kind) {
            1 => 4,
            4 => 16,
            _ => (await reader.take(1))[0],
          } +
          2,
    );
    if (reply != 0) {
      throw SocketException('SOCKS proxy could not reach ${url.host}:$port: ${_socksReplies[reply] ?? 'error $reply'}');
    }
    if (url.scheme != 'https') return _Tunnel(socket, reader.rest());
    // TLS takes the raw socket over; the handshake's reader hears nothing more.
    reader.pause();
    return socket;
  } catch (_) {
    reader.cancel();
    rethrow;
  }
}

InternetAddress? _address(Uri proxy) => InternetAddress.tryParse(proxy.host);

const _socksReplies = {
  1: 'general failure',
  2: 'not allowed by the ruleset',
  3: 'network unreachable',
  4: 'host unreachable',
  5: 'connection refused',
  6: 'TTL expired',
  7: 'command not supported',
  8: 'address type not supported',
};

/// Reads exact byte counts off a socket, then hands what follows to a stream.
final class _ByteReader {
  final List<int> _buffer = [];
  late final StreamSubscription<Uint8List> _sub;
  Completer<void>? _more;
  Object? _error;
  var _done = false;
  StreamController<Uint8List>? _rest;

  _ByteReader(Socket socket) {
    _sub = socket.listen(
      (chunk) {
        if (_rest case final rest?) return rest.add(chunk);
        _buffer.addAll(chunk);
        _wake();
      },
      onError: (Object e) {
        if (_rest case final rest?) return rest.addError(e);
        _error = e;
        _wake();
      },
      onDone: () {
        if (_rest case final rest?) return unawaited(rest.close());
        _done = true;
        _wake();
      },
    );
  }

  void _wake() {
    final more = _more;
    _more = null;
    more?.complete();
  }

  Future<List<int>> take(int n) async {
    while (_buffer.length < n) {
      if (_error case final e?) throw e;
      if (_done) throw const SocketException('SOCKS proxy closed the connection');
      await (_more = Completer<void>()).future;
    }
    final out = _buffer.sublist(0, n);
    _buffer.removeRange(0, n);
    return out;
  }

  void pause() => _sub.pause();

  void cancel() => unawaited(_sub.cancel());

  /// What the socket sends from here on.
  Stream<Uint8List> rest() {
    final rest = _rest = StreamController<Uint8List>(
      sync: true,
      onPause: _sub.pause,
      onResume: _sub.resume,
      onCancel: _sub.cancel,
    );
    if (_buffer.isNotEmpty) rest.add(Uint8List.fromList(_buffer));
    _buffer.clear();
    if (_done) unawaited(rest.close());
    return rest.stream;
  }
}

/// A socket whose reading began before `HttpClient` got it: reads come from [_reads], all
/// else is the socket's.
final class _Tunnel extends StreamView<Uint8List> implements Socket {
  final Socket _socket;

  _Tunnel(this._socket, Stream<Uint8List> reads) : super(reads);

  @override
  Encoding get encoding => _socket.encoding;
  @override
  set encoding(Encoding value) => _socket.encoding = value;
  @override
  void add(List<int> data) => _socket.add(data);
  @override
  void addError(Object error, [StackTrace? stackTrace]) => _socket.addError(error, stackTrace);
  @override
  Future<void> addStream(Stream<List<int>> stream) => _socket.addStream(stream);
  @override
  Future<void> close() => _socket.close();
  @override
  Future<void> get done => _socket.done;
  @override
  Future<void> flush() => _socket.flush();
  @override
  void write(Object? object) => _socket.write(object);
  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) => _socket.writeAll(objects, separator);
  @override
  void writeCharCode(int charCode) => _socket.writeCharCode(charCode);
  @override
  void writeln([Object? object = '']) => _socket.writeln(object);
  @override
  InternetAddress get address => _socket.address;
  @override
  int get port => _socket.port;
  @override
  InternetAddress get remoteAddress => _socket.remoteAddress;
  @override
  int get remotePort => _socket.remotePort;
  @override
  void destroy() => _socket.destroy();
  @override
  bool setOption(SocketOption option, bool enabled) => _socket.setOption(option, enabled);
  @override
  Uint8List getRawOption(RawSocketOption option) => _socket.getRawOption(option);
  @override
  void setRawOption(RawSocketOption option) => _socket.setRawOption(option);
}
