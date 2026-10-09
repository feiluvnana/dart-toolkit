part of '../native.dart';

/// How long a download may wait for a connection, and then for each piece of it.
const _patience = Duration(seconds: 30);

extension _Installer on NativeHandle {
  /// [NativeHandle.install].
  Future<void> _install(Work work, String releases, String cargo) async {
    if (_override != null) return; // the caller's own file: not ours to replace
    final dest = _built ?? (throw NativeException('install dart_toolkit_$name', 'no Rust sources in this package'));
    await _lock(dest, () async {
      if (_versionAt(dest) == abi) return;
      final missed = await _download(dest, work, releases);
      if (missed == null) return;
      final error = await _compile(dest, work, cargo);
      if (error != null) throw NativeException('install dart_toolkit_$name', '$missed; $error');
    });
    _tried = false;
    if (reason != null && _versionAt(dest) == abi) {
      // The OS may keep a library loaded once, at its path, for the life of the process.
      _reason = 'installed $dest at ABI $abi; this process holds the old one, so the next run loads it';
    }
  }

  /// [NativeHandle.build].
  String? _build() {
    final dest = _built;
    if (dest == null) return 'no Rust sources in this package to build dart_toolkit_$name from';
    final crate = _crateOf(dest), target = _join([crate, 'target']);
    final ProcessResult run;
    try {
      run = Process.runSync('cargo', _cargoArgs(target), workingDirectory: crate);
    } on ProcessException {
      return _noCargo;
    }
    if (run.exitCode != 0) return _cargoFailed('${run.stderr}');
    _place(target, dest);
    return null;
  }

  /// [body] under a lock beside [dest], one process at a time.
  Future<void> _lock(String dest, Future<void> Function() body) async {
    final RandomAccessFile lock;
    try {
      await Directory(File(dest).parent.path).create(recursive: true);
      lock = await File('$dest.lock').open(mode: FileMode.append);
      await lock.lock(FileLock.blockingExclusive);
    } on FileSystemException catch (e) {
      throw NativeException('install dart_toolkit_$name', 'cannot lock $dest: ${e.message}');
    }
    try {
      await body();
    } finally {
      await lock.close();
    }
  }

  /// [dest]'s crate: `native/` of `native/lib/<os>_<arch>/<file>`.
  static String _crateOf(String dest) => File(dest).parent.parent.parent.path;

  /// Fetches this platform's build from the release `native-<hash of the sources>`, which
  /// `make native-release` uploads, so a binary always matches the sources beside it; its
  /// `.sha256` beside it must agree. Answers why it could not, or `null`.
  Future<String?> _download(String dest, Work work, String releases) async {
    final tag = 'native-${NativeBridge.sourceHash(_crateOf(dest))}';
    final asset = NativeBridge.assetOf(name, NativeBridge.target);
    final url = '$releases/$tag/$asset';
    work.step('downloading dart_toolkit_$name');
    final client = HttpClient()..connectionTimeout = _patience;
    try {
      final published = await _fetch(client, Uri.parse('$url.sha256'), null);
      if (published == null) return 'no $asset.sha256 in release $tag';
      final digest = ascii.decode(published, allowInvalid: true).trim().split(RegExp(r'\s+')).first.toLowerCase();
      final gz = await _fetch(client, Uri.parse(url), work);
      if (gz == null) return 'no $asset in release $tag';
      if (_sha256Hex(gz) != digest) return '$url does not match its published SHA-256';
      final temp = '$dest.$pid.tmp';
      try {
        await File(temp).writeAsBytes(gzip.decode(gz));
        // A rename, so a process loading the old file keeps it and the next one sees the new.
        await File(temp).rename(dest);
      } on FormatException {
        return '$url is not gzip';
      } on FileSystemException catch (e) {
        await FileBridge.gone(temp);
        return 'could not write $dest: ${e.message}';
      }
      return _versionAt(dest) == abi ? null : '$url is not dart_toolkit_$name at ABI $abi';
    } on SocketException catch (e) {
      return 'could not download $url: ${e.message}';
    } on HttpException catch (e) {
      return 'could not download $url: ${e.message}';
    } on TimeoutException {
      return 'could not download $url: no answer for ${_patience.inSeconds}s';
    } on TlsException catch (e) {
      return 'could not download $url: ${e.message}';
    } finally {
      client.close(force: true);
    }
  }

  /// The body at [url], or `null` when it is not there; with [work], its bytes are reported.
  static Future<Uint8List?> _fetch(HttpClient client, Uri url, Work? work) async {
    final request = await client.getUrl(url).timeout(_patience);
    final response = await request.close().timeout(_patience);
    if (response.statusCode != 200) {
      await response.drain<void>();
      return response.statusCode == 404 ? null : throw HttpException('HTTP ${response.statusCode}', uri: url);
    }
    final total = response.contentLength < 0 ? null : response.contentLength;
    final body = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(_patience)) {
      if (work != null) Cancel.check();
      body.add(chunk);
      work?.amount(body.length, total: total);
    }
    return body.takeBytes();
  }

  static const _noCargo = 'cargo is not on PATH: install Rust from https://rustup.rs';

  List<String> _cargoArgs(String target) => ['build', '--release', '-p', 'dart_toolkit_$name', '--target-dir', target];

  String _cargoFailed(String stderr) {
    final lines = stderr.trim().split('\n');
    final tail = lines.length > 5 ? lines.sublist(lines.length - 5) : lines;
    return 'cargo could not build dart_toolkit_$name: ${tail.join('\n')}';
  }

  /// The library cargo built under [target] put at [dest] by a rename.
  void _place(String target, String dest) {
    final temp = '$dest.$pid.tmp';
    Directory(File(dest).parent.path).createSync(recursive: true);
    File(_join([target, 'release', NativeBridge.fileOf(name)])).copySync(temp);
    FileBridge.renameSync(File(temp), dest);
  }

  /// Compiles this library with [cargo] into [dest], telling [work] each crate it compiles. A
  /// cargo tree this made is deleted after, built or not, so a package in the pub cache keeps
  /// the library and not the gigabytes that built it. A cancel stops cargo.
  Future<String?> _compile(String dest, Work work, String cargo) async {
    final crate = _crateOf(dest), target = _join([crate, 'target']);
    final fresh = !await Directory(target).exists();
    work.step('compiling dart_toolkit_$name');
    final Process process;
    try {
      process = await Process.start(cargo, _cargoArgs(target), workingDirectory: crate);
    } on ProcessException {
      return _noCargo;
    }
    // The whole tree: cargo dies alone on a signal, and its rustc children write on.
    Future<void>? killed;
    final stop = Cancel.token?.onCancel(() => killed = _killTree(process.pid));
    try {
      final stderr = StringBuffer();
      final out = process.stdout.drain<void>();
      await for (final line in process.stderr.transform(utf8.decoder).transform(const LineSplitter())) {
        stderr.writeln(line);
        final compiling = line.trimLeft();
        if (compiling.startsWith('Compiling ')) work.step('compiling ${compiling.substring(10).split(' ').first}');
      }
      await out;
      final code = await process.exitCode;
      Cancel.check();
      if (code != 0) return _cargoFailed('$stderr');
      _place(target, dest);
      return null;
    } finally {
      stop?.call();
      await killed;
      if (fresh) await FileBridge.gone(target);
    }
  }

  /// The ABI of the library at [path], read in a throwaway open; `null` when it is absent or
  /// will not open.
  int? _versionAt(String path) {
    if (!File(path).existsSync()) return null;
    try {
      final lib = DynamicLibrary.open(path);
      final ver = NativeHandle._version(lib);
      if (ver != abi) lib.close();
      return ver;
    } catch (_) {
      return null; // not a library this process can open: installed again
    }
  }
}

/// The process [pid] and everything under it killed, children first found: `taskkill /T` on
/// Windows, else each found by `pgrep -P` while it is stopped, so none is started meanwhile.
Future<void> _killTree(int pid) async {
  if (Platform.isWindows) {
    await Process.run('taskkill', ['/T', '/F', '/PID', '$pid']);
    return;
  }
  Process.killPid(pid, ProcessSignal.sigstop);
  final children = await Process.run('pgrep', ['-P', '$pid']);
  for (final child in '${children.stdout}'.split('\n').map(int.tryParse).nonNulls) {
    await _killTree(child);
  }
  Process.killPid(pid, ProcessSignal.sigkill);
}

/// SHA-256 of [data] in hex, in Dart: what checks a download before any native code loads.
String _sha256Hex(Uint8List data) {
  const k = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, //
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ];
  final h = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
  // The message, a 1 bit, zeros, and its length in bits: a whole number of 64-byte blocks.
  final padded = Uint8List(((data.length + 9 + 63) ~/ 64) * 64)
    ..setAll(0, data)
    ..[data.length] = 0x80;
  ByteData.sublistView(padded).setUint64(padded.length - 8, data.length * 8);
  final view = ByteData.sublistView(padded);
  final w = Uint32List(64);
  int rotr(int x, int n) => ((x >>> n) | (x << (32 - n))) & 0xffffffff;
  for (var block = 0; block < padded.length; block += 64) {
    for (var i = 0; i < 16; i++) {
      w[i] = view.getUint32(block + i * 4);
    }
    for (var i = 16; i < 64; i++) {
      final s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >>> 3);
      final s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >>> 10);
      w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    var [a, b, c, d, e, f, g, hh] = h;
    for (var i = 0; i < 64; i++) {
      final t1 = (hh + (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) + ((e & f) ^ (~e & g)) + k[i] + w[i]) & 0xffffffff;
      final t2 = ((rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) + ((a & b) ^ (a & c) ^ (b & c))) & 0xffffffff;
      (hh, g, f, e, d, c, b, a) = (g, f, e, (d + t1) & 0xffffffff, c, b, a, (t1 + t2) & 0xffffffff);
    }
    for (final (i, v) in [a, b, c, d, e, f, g, hh].indexed) {
      h[i] = (h[i] + v) & 0xffffffff;
    }
  }
  return [for (final v in h) v.toRadixString(16).padLeft(8, '0')].join();
}
