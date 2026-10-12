// The native engine the package loads: the library bound by explicit path agrees with the
// loader's surface (`Hash.*`), the streaming handles and known-answer vectors, and the seam
// reports whether it loaded. There is no Dart fallback (rule 42); when the library hasn't been
// built, the binding tests skip with a message instead of failing.

import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:dart_toolkit/hash.dart';
import 'package:dart_toolkit/native.dart';
import 'package:dart_toolkit/testing.dart';
import 'package:test/test.dart';

typedef _U8 = ffi.Pointer<ffi.Uint8>;
typedef _Handle = ffi.Pointer<ffi.Void>;

/// The rewritten cdylib, bound by explicit path (never the loader's search path).
abstract final class _N2 {
  static ffi.DynamicLibrary? _lib;

  static String? get path {
    final override = io.Platform.environment['NATIVE_DLL'];
    if (override != null) return io.File(override).existsSync() ? override : null;
    const candidates = [
      'native/target/debug/dart_toolkit_native.dll',
      'native/target/release/dart_toolkit_native.dll',
      'native/target/debug/libdart_toolkit_native.so',
      'native/target/release/libdart_toolkit_native.so',
      'native/target/debug/libdart_toolkit_native.dylib',
      'native/target/release/libdart_toolkit_native.dylib',
    ];
    for (final c in candidates) {
      if (io.File(c).existsSync()) return c;
    }
    return null;
  }

  static ffi.DynamicLibrary require() {
    if (_lib != null) return _lib!;
    final p = path;
    if (p == null) {
      markTestSkipped('native engine not built yet: `cargo build --manifest-path native/engine/Cargo.toml`');
    }
    return _lib = ffi.DynamicLibrary.open(p!);
  }

  static final version = require().lookupFunction<ffi.Uint32 Function(), int Function()>('tk_version');

  static final digestNew = require().lookupFunction<_Handle Function(ffi.Uint32), _Handle Function(int)>(
    'tk_digest_new',
  );

  static final digestUpdate = require()
      .lookupFunction<ffi.Int32 Function(_Handle, _U8, ffi.IntPtr), int Function(_Handle, _U8, int)>(
        'tk_digest_update',
      );

  static final digestFinal = require()
      .lookupFunction<ffi.Int32 Function(_Handle, _U8, ffi.IntPtr), int Function(_Handle, _U8, int)>('tk_digest_final');

  static final digest = require()
      .lookupFunction<
        ffi.Int32 Function(ffi.Uint32, _U8, ffi.IntPtr, _U8, ffi.IntPtr),
        int Function(int, _U8, int, _U8, int)
      >('tk_digest');

  static final hmac = require()
      .lookupFunction<
        ffi.Int32 Function(ffi.Uint32, _U8, ffi.IntPtr, _U8, ffi.IntPtr, _U8, ffi.IntPtr),
        int Function(int, _U8, int, _U8, int, _U8, int)
      >('tk_hmac');

  static final digestFile = require()
      .lookupFunction<
        ffi.Int32 Function(_Handle, _U8, ffi.IntPtr, ffi.Pointer<ffi.Void>, _U8),
        int Function(_Handle, _U8, int, ffi.Pointer<ffi.Void>, _U8)
      >('tk_digest_file');

  static final digestFiles = require()
      .lookupFunction<
        ffi.Int32 Function(ffi.Uint32, _U8, ffi.IntPtr, _U8, ffi.IntPtr, _U8),
        int Function(int, _U8, int, _U8, int, _U8)
      >('tk_digest_files');

  static final lastError = require().lookupFunction<ffi.Int32 Function(_U8, ffi.IntPtr), int Function(_U8, int)>(
    'tk_last_error',
  );

  static final alloc = require().lookupFunction<_U8 Function(ffi.IntPtr), _U8 Function(int)>('tk_alloc');

  static final dealloc = require().lookupFunction<ffi.Void Function(_U8, ffi.IntPtr), void Function(_U8, int)>(
    'tk_dealloc',
  );

  /// [size] zeroed bytes from the library's own allocator, freed with [free].
  static _U8 calloc(int size) {
    final ptr = alloc(size);
    ptr.asTypedList(size).fillRange(0, size, 0);
    return ptr;
  }

  static void free(_U8 ptr, int size) => dealloc(ptr, size);

  static String error() {
    final buf = calloc(1024);
    try {
      final n = lastError(buf, 1024);
      if (n <= 0) return 'unknown error';
      return utf8.decode(buf.asTypedList(n < 1024 ? n : 1024), allowMalformed: true);
    } finally {
      free(buf, 1024);
    }
  }
}

String hexOf(Uint8List b) => Digest(b).hex;

/// Every algorithm under test.
const _algos = [Hash.md5, Hash.sha256, Hash.sha512, Hash.crc32, Hash.blake3, Hash.xxh64, Hash.xxh3];

/// The native `tk_digest_*` algorithm code for [algo]: the explicit bindings
/// below need it raw (`Algo.code` is private).
int _codeOf(Algo algo) => switch (algo.name) {
  'md5' => 0,
  'sha256' => 3,
  'sha512' => 5,
  'blake3' => 14,
  'crc32' => 16,
  'xxh64' => 18,
  'xxh3' => 19,
  _ => throw ArgumentError.value(algo.name, 'algo', 'Unknown algorithm'),
};

/// [data] digested by the rewritten one-shot.
Uint8List n2oneshot(int code, List<int> data) {
  final n = data.length;
  final buf = _N2.calloc(n + 64);
  try {
    final view = buf.asTypedList(n + 64);
    view.setAll(0, data);
    final dp = buf;
    final op = ffi.Pointer<ffi.Uint8>.fromAddress(buf.address + n);
    final len = _N2.digest(code, dp, n, op, 64);
    if (len < 0) throw StateError('native tk_digest: ${_N2.error()}');
    return Uint8List.fromList(view.sublist(n, n + len));
  } finally {
    _N2.free(buf, n + 64);
  }
}

/// [data] digested by the rewritten handle in [step]-byte chunks.
Uint8List n2stream(int code, List<int> data, int step) {
  final h = _N2.digestNew(code);
  if (h == ffi.nullptr) throw StateError('native tk_digest_new: ${_N2.error()}');
  final buf = _N2.calloc(step);
  try {
    final view = buf.asTypedList(step);
    for (var at = 0; at < data.length; at += step) {
      final n = data.length - at < step ? data.length - at : step;
      view.setRange(0, n, data, at);
      if (_N2.digestUpdate(h, buf, n) < 0) throw StateError('native tk_digest_update: ${_N2.error()}');
    }
  } finally {
    _N2.free(buf, step);
  }
  final out = _N2.calloc(64);
  try {
    final len = _N2.digestFinal(h, out, 64);
    if (len < 0) throw StateError('native tk_digest_final: ${_N2.error()}');
    return Uint8List.fromList(out.asTypedList(len));
  } finally {
    _N2.free(out, 64);
  }
}

void main() {
  group('native seam', () {
    test('reports loaded or a reason', () {
      if (Native.ok) {
        expect(Native.reason, isNull);
      } else {
        expect(Native.reason, isNotNull);
      }
    });
  });

  test('rewritten cdylib reports ABI 2', () {
    expect(_N2.version(), 2);
  });

  group('parity: explicit bindings == loader surface', () {
    test('one-shot, small and multi-chunk', () async {
      final small = Uint8List.fromList(utf8.encode('abc'));
      final big = Uint8List.fromList(List.generate(300000, (i) => (i * 7 + 3) & 0xFF));
      for (final algo in _algos) {
        for (final data in [small, big]) {
          final bound = hexOf(n2oneshot(_codeOf(algo), data));
          NativeReset.all();
          final surface = hexOf(algo(data));
          expect(bound, surface, reason: '${algo.name} binding vs surface len=${data.length}');
        }
      }
    });

    test('handle streaming equals the one-shot', () async {
      final data = Uint8List.fromList(List.generate(200000, (i) => (i * 31 + 7) & 0xFF));
      for (final algo in _algos) {
        expect(hexOf(n2stream(_codeOf(algo), data, 137)), hexOf(n2oneshot(_codeOf(algo), data)), reason: algo.name);
      }
    });

    test('HMAC RFC 4231 case 2', () {
      final key = utf8.encode('Jefe'), data = utf8.encode('what do ya want for nothing?');
      final buf = _N2.calloc(key.length + data.length + 64);
      try {
        final view = buf.asTypedList(key.length + data.length + 64);
        view.setAll(0, key);
        view.setAll(key.length, data);
        final kp = buf;
        final dp = ffi.Pointer<ffi.Uint8>.fromAddress(buf.address + key.length);
        final op = ffi.Pointer<ffi.Uint8>.fromAddress(buf.address + key.length + data.length);
        final n = _N2.hmac(3, kp, key.length, dp, data.length, op, 64);
        expect(n, greaterThan(0));
        expect(
          hexOf(Uint8List.fromList(view.sublist(key.length + data.length, key.length + data.length + n))),
          '5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843',
        );
      } finally {
        _N2.free(buf, key.length + data.length + 64);
      }
    });

    test('file ingest equals the one-shot', () async {
      final tmp = await io.Directory.systemTemp.createTemp('n2_parity_');
      try {
        final data = Uint8List.fromList(List.generate(200000, (i) => (i * 7 + 3) & 0xFF));
        final path = '${tmp.path}/big.bin';
        await io.File(path).writeAsBytes(data);
        final h = _N2.digestNew(3);
        expect(h, isNot(equals(ffi.nullptr)));
        final units = utf8.encode(path);
        final buf = _N2.calloc(units.length);
        try {
          buf.asTypedList(units.length).setAll(0, units);
          expect(_N2.digestFile(h, buf, units.length, ffi.nullptr, ffi.nullptr), 0);
        } finally {
          _N2.free(buf, units.length);
        }
        final out = _N2.calloc(64);
        try {
          final n = _N2.digestFinal(h, out, 64);
          expect(n, greaterThan(0));
          final got = Uint8List.fromList(out.asTypedList(n));
          expect(hexOf(got), hexOf(n2oneshot(3, data)));
        } finally {
          _N2.free(out, 64);
        }
        // Missing file: negative with an "(os error N)" message the Dart side maps.
        final h2 = _N2.digestNew(3);
        final miss = utf8.encode('${tmp.path}/gone.bin');
        final buf2 = _N2.calloc(miss.length);
        try {
          buf2.asTypedList(miss.length).setAll(0, miss);
          expect(_N2.digestFile(h2, buf2, miss.length, ffi.nullptr, ffi.nullptr), lessThan(0));
          expect(_N2.error(), contains('os error'));
        } finally {
          _N2.free(buf2, miss.length);
        }
        final out2 = _N2.calloc(64);
        try {
          // The session survives the failure; final still releases it.
          expect(_N2.digestFinal(h2, out2, 64), greaterThan(0));
        } finally {
          _N2.free(out2, 64);
        }
      } finally {
        await tmp.delete(recursive: true);
      }
    });

    test('multi-file digests land back to back in order', () async {
      final tmp = await io.Directory.systemTemp.createTemp('n2_parity_files_');
      try {
        final a = '${tmp.path}/a.bin', b = '${tmp.path}/b.bin';
        await io.File(a).writeAsBytes([1, 2, 3]);
        await io.File(b).writeAsBytes([4, 5]);
        final joined = utf8.encode('$a\x00$b');
        final inBuf = _N2.calloc(joined.length);
        final outBuf = _N2.calloc(64);
        try {
          inBuf.asTypedList(joined.length).setAll(0, joined);
          final n = _N2.digestFiles(3, inBuf, joined.length, outBuf, 64, ffi.nullptr);
          expect(n, 2);
          final out = outBuf.asTypedList(64);
          expect(hexOf(Uint8List.fromList(out.sublist(0, 32))), hexOf(Hash.sha256([1, 2, 3])));
          expect(hexOf(Uint8List.fromList(out.sublist(32, 64))), hexOf(Hash.sha256([4, 5])));
        } finally {
          _N2.free(inBuf, joined.length);
          _N2.free(outBuf, 64);
        }
      } finally {
        await tmp.delete(recursive: true);
      }
    });
  });
}
