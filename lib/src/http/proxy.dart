// proxy: http:// and socks5:// proxies for a client's connections.
part of '../../http.dart';

/// A `proxy:` setting, checked when the client is made.
final class _Proxy {
  _Proxy._(this.socks, this.host, this.port, this.user, this.pass);

  /// `[http|socks5|socks5h]://[user:pass@]host[:port]`; the port defaults
  /// to 1080, as in curl.
  factory _Proxy.parse(String text) {
    final Uri u;
    try {
      u = Uri.parse(text.contains('://') ? text : 'http://$text');
    } on FormatException catch (e) {
      throw ArgumentError.value(names.redact(text), 'proxy', 'invalid proxy URL: ${e.message}');
    }
    final socks = switch (u.scheme) {
      'http' => false,
      'socks5' || 'socks5h' => true,
      _ => throw ArgumentError.value(names.redact(text), 'proxy', 'must be http://, socks5:// or socks5h://'),
    };
    if (u.host.isEmpty) throw ArgumentError.value(names.redact(text), 'proxy', 'has no host');
    String? user, pass;
    if (u.userInfo.isNotEmpty) {
      final colon = u.userInfo.indexOf(':');
      user = Uri.decodeComponent(colon < 0 ? u.userInfo : u.userInfo.substring(0, colon));
      pass = colon < 0 ? '' : Uri.decodeComponent(u.userInfo.substring(colon + 1));
      // RFC 1929 sends each in one length byte.
      if (socks && (utf8.encode(user).length > 255 || utf8.encode(pass).length > 255)) {
        throw ArgumentError.value(names.redact(text), 'proxy', 'SOCKS user and password are at most 255 bytes');
      }
    }
    return _Proxy._(socks, u.host, u.hasPort ? u.port : 1080, user, pass);
  }

  final bool socks;
  final String host;
  final int port;
  final String? user, pass;

  /// Route [c] through this proxy; a SOCKS handshake that takes longer
  /// than [timeout] fails.
  void apply(HttpClient c, Duration timeout) {
    if (!socks) {
      c.findProxy = (_) => 'PROXY $host:$port';
      if (user != null) c.addProxyCredentials(host, port, '', HttpClientBasicCredentials(user!, pass!));
      return;
    }
    c.findProxy = (_) => 'DIRECT';
    c.connectionFactory = (url, _, _) async {
      final task = await Socket.startConnect(host, port);
      Socket? connected;
      final socket = task.socket.then((s) {
        connected = s;
        return _socks(s, url).timeout(
          timeout,
          onTimeout: () {
            s.destroy();
            throw SocketException('SOCKS proxy $host:$port: no answer for ${timeout.inMilliseconds} ms');
          },
        );
      }, onError: (Object e) => throw SocketException('SOCKS proxy $host:$port: $e'));
      return ConnectionTask.fromSocket(socket, () {
        task.cancel();
        connected?.destroy();
      });
    };
  }

  /// The SOCKS5 handshake (RFC 1928, user/pass RFC 1929) to [url]'s host,
  /// resolved by the proxy; then TLS for https.
  Future<Socket> _socks(Socket s, Uri url) async {
    final input = _Input(s);
    try {
      final auth = user != null;
      s.add([5, auth ? 2 : 1, 0, if (auth) 2]);
      final [version, method] = await input.read(2);
      if (version != 5) throw const SocketException('SOCKS proxy: not a SOCKS5 server');
      if (method == 2 && auth) {
        final u = utf8.encode(user!), p = utf8.encode(pass!);
        s.add([1, u.length, ...u, p.length, ...p]);
        if ((await input.read(2))[1] != 0) throw const SocketException('SOCKS proxy: login refused');
      } else if (method != 0) {
        throw const SocketException('SOCKS proxy: no acceptable login method');
      }
      final ip = InternetAddress.tryParse(url.host);
      final name = utf8.encode(url.host);
      // One length byte: a longer name would make the proxy read another host.
      if (ip == null && name.length > 255) throw SocketException('SOCKS proxy: host name over 255 bytes: ${url.host}');
      s.add([
        5, 1, 0, //
        ...switch (ip?.type) {
          InternetAddressType.IPv4 => [1, ...ip!.rawAddress],
          InternetAddressType.IPv6 => [4, ...ip!.rawAddress],
          _ => [3, name.length, ...name],
        },
        url.port >> 8, url.port & 0xFF,
      ]);
      final [_, reply, _, type] = await input.read(4);
      if (reply != 0) {
        throw SocketException('SOCKS proxy: ${_socksReplies[reply] ?? 'error $reply'} for ${url.host}:${url.port}');
      }
      await input.read(switch (type) {
        1 => 4 + 2,
        4 => 16 + 2,
        _ => (await input.read(1))[0] + 2,
      });
    } catch (_) {
      s.destroy();
      rethrow;
    }
    input.sub.pause();
    if (url.scheme == 'https') {
      return SecureSocket.secure(s, host: url.host);
    }
    return _Tunnel(s, input.sub);
  }
}

const _socksReplies = {
  1: 'general failure',
  2: 'connection not allowed',
  3: 'network unreachable',
  4: 'host unreachable',
  5: 'connection refused',
  6: 'TTL expired',
  7: 'command not supported',
  8: 'address type not supported',
};

/// Exact-length reads from a socket during a handshake.
final class _Input {
  _Input(Socket s) {
    sub = s.listen(
      (d) {
        _buf.add(d);
        _wake();
      },
      onError: (Object e) {
        _error = e;
        _wake();
      },
      onDone: () {
        _error ??= const SocketException('SOCKS proxy closed the connection');
        _wake();
      },
    );
  }

  late final StreamSubscription<Uint8List> sub;
  final _buf = BytesBuilder();
  Object? _error;
  Completer<void>? _waiter;

  void _wake() {
    _waiter?.complete();
    _waiter = null;
  }

  Future<List<int>> read(int n) async {
    while (_buf.length < n) {
      if (_error case final e?) throw e;
      await (_waiter = Completer<void>()).future;
    }
    final all = _buf.takeBytes();
    _buf.add(Uint8List.sublistView(all, n));
    return Uint8List.sublistView(all, 0, n);
  }
}

/// A plain socket after a SOCKS handshake: the handshake's subscription
/// carries on as this stream, the rest is the socket itself.
final class _Tunnel extends Stream<Uint8List> implements Socket {
  _Tunnel(this._s, StreamSubscription<Uint8List> sub) {
    _out = StreamController<Uint8List>(
      sync: true,
      onListen: sub.resume,
      onPause: sub.pause,
      onResume: sub.resume,
      onCancel: sub.cancel,
    );
    sub
      ..onData(_out.add)
      ..onError(_out.addError)
      ..onDone(_out.close);
  }

  final Socket _s;
  late final StreamController<Uint8List> _out;

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _out.stream.listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);

  @override
  Encoding get encoding => _s.encoding;

  @override
  set encoding(Encoding value) => _s.encoding = value;

  @override
  void add(List<int> data) => _s.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) => _s.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<List<int>> stream) => _s.addStream(stream);

  @override
  Future<void> close() => _s.close();

  @override
  Future<void> get done => _s.done;

  @override
  Future<void> flush() => _s.flush();

  @override
  void write(Object? object) => _s.write(object);

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) => _s.writeAll(objects, separator);

  @override
  void writeCharCode(int charCode) => _s.writeCharCode(charCode);

  @override
  void writeln([Object? object = '']) => _s.writeln(object);

  @override
  InternetAddress get address => _s.address;

  @override
  int get port => _s.port;

  @override
  InternetAddress get remoteAddress => _s.remoteAddress;

  @override
  int get remotePort => _s.remotePort;

  @override
  bool setOption(SocketOption option, bool enabled) => _s.setOption(option, enabled);

  @override
  Uint8List getRawOption(RawSocketOption option) => _s.getRawOption(option);

  @override
  void setRawOption(RawSocketOption option) => _s.setRawOption(option);

  @override
  void destroy() => _s.destroy();
}
