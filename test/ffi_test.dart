import 'dart:async';
import 'dart:ffi' show Uint8Pointer, nullptr;
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_toolkit/ffi.dart';
import 'package:dart_toolkit/native.dart';
import 'package:test/test.dart';

void main() {
  // The libc tests name POSIX functions; Windows spells half of them with an underscore.
  final posix = Platform.isWindows ? 'POSIX libc symbols' : null;
  final libc = Ffi.open('c');

  group('Ffi.open', () {
    test('finds the C runtime by its short name', () {
      expect(libc.has('strlen'), isTrue);
      expect(libc.has('no_such_function_here'), isFalse);
    });

    test('an unknown library names everything it tried', () {
      expect(
        () => Ffi.open('no_such_library_xyz'),
        throwsA(isA<ArgumentError>().having((e) => e.message, 'message', contains('no_such_library_xyz'))),
      );
    });

    test('an unknown symbol is refused at binding time', () {
      expect(() => libc.fn('no_such_function_here', C.i32), throwsArgumentError);
    });
  });

  group('calls', () {
    test('a String goes in as UTF-8', () {
      final strlen = libc.fn('strlen', C.i64);
      expect(strlen('hello'), 5);
      expect(strlen('名前'), 6);
      expect(strlen(''), 0);
    });

    test('no arguments, and a narrowed int return', () {
      expect(libc.call('getpid', C.i32), pid);
    }, skip: posix);

    test('a negative int round-trips through a 32-bit return', () {
      expect(libc.call('abs', C.i32, -42), 42);
      expect(libc.call('atoi', C.i32, '-17'), -17);
    });

    test('a char* comes back as a String, NULL as null', () {
      final home = Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'];
      expect(libc.call('getenv', C.str, Platform.isWindows ? 'USERPROFILE' : 'HOME'), home);
      expect(libc.call('getenv', C.str, 'DART_TOOLKIT_SURELY_UNSET_VAR'), isNull);
    });

    test('doubles', () {
      final libm = Platform.isLinux ? Ffi.open('m') : libc;
      expect(libm.call('pow', C.f64, 2.0, 10.0), 1024.0);
      expect(libm.call('sqrt', C.f64, 2.0), closeTo(1.41421356, 1e-8));
    });

    group('mixed integers and doubles', () {
      final libm = Platform.isLinux ? Ffi.open('m') : libc;

      test('a double return from integer and string arguments', () {
        expect(libc.call('atof', C.f64, '2.5'), 2.5);
        expect(libc.call('strtod', C.f64, '-0.125xyz', null), -0.125);
      });

      test('both kinds in one call, each in its own order', () {
        expect(libm.call('ldexp', C.f64, 1.0, 10), 1024.0);
        expect(libm.call('lround', C.i64, 2.6), 3);
        expect(libm.call('fma', C.f64, 2.0, 3.0, 4.0), 10.0);
      }, skip: Platform.isWindows ? 'Win64 passes arguments by position' : null);

      test('Windows refuses a mix instead of passing it in the wrong registers', () {
        expect(() => libm.call('ldexp', C.f64, 1.0, 10), throwsArgumentError);
      }, skip: Platform.isWindows ? null : 'only Windows refuses');
    });

    test('a float argument and return', () {
      final libm = Platform.isLinux ? Ffi.open('m') : libc;
      expect(libm.call('sqrtf', C.f32, C.f32(2.0)), closeTo(1.4142135, 1e-6));
      expect(libm.call('powf', C.f32, C.f32(2.0), C.f32(10.0)), 1024.0);
    });

    test('a key narrows a value: C.i8(255), C.u8(-1), C.i32 of a zero-extended slot', () {
      expect(C.i8(255), -1);
      expect(C.u8(-1), 255);
      expect(C.i32(0xffffffff), -1);
      expect(C.i64(1 << 40), 1 << 40);
    });

    test('an unmodifiable typed list goes in only', () {
      final data = Uint8List.fromList([1, 2, 3, 4]).asUnmodifiableView();
      libc.call('memset', C.ptr, data, 9, data.length);
      expect(data, [1, 2, 3, 4]);
    });

    test('a typed list is written back', () {
      final buf = Uint8List(256);
      expect(libc.call('gethostname', C.i32, buf, buf.length), 0);
      final name = String.fromCharCodes(buf.takeWhile((b) => b != 0));
      expect(name, isNotEmpty);
      expect(name.toLowerCase(), Platform.localHostname.toLowerCase());
    }, skip: posix);

    test('a plain List is refused with the fix in the message', () {
      expect(
        () => libc.call('strlen', C.i64, [104, 105, 0]),
        throwsA(isA<ArgumentError>().having((e) => e.message, 'message', contains('Uint8List'))),
      );
    });
  });

  group('variadic', () {
    test('snprintf with integers, a string and a double', () {
      final buf = Uint8List(64);
      final n = libc.fn('snprintf', C.i32, fixed: 3)(buf, buf.length, '%d %s %.2f', 42, 'hi', 3.14159);
      expect(String.fromCharCodes(buf.take(n)), '42 hi 3.14');
    });

    test('a double among the fixed arguments is refused', () {
      expect(() => libc.fn('printf', C.i32, fixed: 1)(1.5), throwsArgumentError);
    });
  });

  group('errno', () {
    test('reads what the failed call left, across its own cleanup', () {
      expect(libc.call('open', C.i32, '/surely/not/here/dart_toolkit', 0), -1);
      expect(Ffi.errno, 2); // ENOENT
    }, skip: posix);
  });

  group('memory', () {
    test('an out-parameter', () {
      Ffi.scope((s) {
        final end = s.out(C.ptr);
        expect(libc.call('strtol', C.i64, s.text('42 rest'), end, 10), 42);
        expect(String.fromCharCodes(C.u8.list(end.value, 5)), ' rest');
        final n = s.out(C.i32)..value = -7;
        expect(n.value, -7);
      });
    });

    test('a list views memory in place', () {
      Ffi.scope((s) {
        final p = s.alloc(16);
        C.i32.list(p, 4)[1] = -5;
        expect(C.i32.at(p.address + 4), -5);
        expect(C.f64.list(p, 2), hasLength(2));
        expect(() => C.str.list(p, 1), throwsUnsupportedError);
      });
      expect(C.i32.list, isNotNull);
    });

    test('a struct lays out like C and reads through its fields', () {
      final a = C.u8.field, b = C.i32.field, c = C.i16.field, d = C.f64.field;
      final layout = C.struct([a, b, c, d]);
      expect(layout.size, 24); // 1 + 3 pad + 4 + 2 + 6 pad + 8
      Ffi.scope((s) {
        final p = s.alloc(layout.size);
        a[p] = 200;
        b[p] = -1;
        c[p] = 7;
        d[p] = 0.5;
        expect((a[p], b[p], c[p], d[p]), (200, -1, 7, 0.5));
        expect(C.i32.at(p.address + 4), -1);
      });
      expect(() => C.struct([a]), throwsArgumentError, reason: 'a field belongs to one struct');
      expect(() => C.i32.field[nullptr], throwsStateError);
    });

    test('clock_gettime fills a timespec', () {
      final sec = C.i64.field, nsec = C.i64.field;
      final timespec = C.struct([sec, nsec]);
      Ffi.scope((s) {
        final ts = s.alloc(timespec.size);
        expect(libc.call('clock_gettime', C.i32, 0, ts), 0);
        expect(sec[ts], closeTo(DateTime.now().millisecondsSinceEpoch ~/ 1000, 5));
        expect(nsec[ts], lessThan(1000000000));
      });
    }, skip: posix);

    test('C.at reads what a scope holds', () {
      Ffi.scope((s) {
        final p = s.alloc(8);
        p.asTypedList(8).setAll(0, [0xff, 0xff, 0xff, 0xff, 1, 0, 0, 0]);
        expect(C.i32.at(p.address), -1);
        expect(C.u32.at(p.address), 0xffffffff);
        expect(C.i8.at(p.address), -1);
        expect(C.u16.at(p.address), 0xffff);
        expect(C.i64.at(p.address), 0x1ffffffff);
        expect(C.str.at(s.alloc(8).address), isNull); // a zeroed char* is NULL
      });
    });

    test('a scope text is a char*', () {
      expect(Ffi.scope((s) => libc.call('strlen', C.i64, s.text('abc'))), 3);
    });

    test('an async scope frees when its future completes', () async {
      final n = await Ffi.scope((s) async {
        final p = s.text('four');
        await Future<void>.delayed(Duration.zero);
        return libc.call('strlen', C.i64, p);
      });
      expect(n, 4);
    });

    test('qsort with a Dart comparator', () {
      final data = Int32List.fromList([5, -3, 9, 0, 42, 7]);
      Ffi.scope(
        (s) =>
            libc.call('qsort', C.none, data, data.length, 4, s.callback((int a, int b) => C.i32.at(a) - C.i32.at(b))),
      );
      expect(data, [-3, 0, 5, 7, 9, 42]);
    });

    test('a callback reads a negative C int with C.i32', () {
      // bsearch hands the comparator pointers; qsort over negative values checks the sign.
      final data = Int32List.fromList([3, -1, -2]);
      Ffi.scope(
        (s) => libc.call(
          'qsort',
          C.none,
          data,
          data.length,
          4,
          s.callback((int a, int b) => C.i32(C.i32.at(a) - C.i32.at(b))),
        ),
      );
      expect(data, [-2, -1, 3]);
    });

    test('a closed callback cannot be passed', () {
      final cb = Ffi.callback(() => 0)..close();
      cb.close();
      expect(() => libc.call('abs', C.i32, cb), throwsStateError);
    });

    test('own frees on close, once', () {
      final h = libc.own(libc.call('malloc', C.ptr, 1024), 'free');
      expect(h.ptr.address, isNot(0));
      expect(libc.call('memset', C.ptr, h, 0, 1024).address, h.ptr.address);
      h.close();
      h.close();
      expect(() => h.ptr, throwsStateError);
      expect(() => libc.call('abs', C.i32, h), throwsStateError);
    });
  });

  group('async', () {
    test('a blocking call leaves the event loop running', () async {
      var ticks = 0;
      final timer = Timer.periodic(const Duration(milliseconds: 10), (_) => ticks++);
      final rc = await libc.fn('usleep', C.i32).async(200000);
      timer.cancel();
      expect(rc, 0);
      expect(ticks, greaterThan(5));
    }, skip: posix);

    test('a typed list is still written back', () async {
      final buf = Uint8List(256);
      expect(await libc.fn('gethostname', C.i32).async(buf, buf.length), 0);
      expect(buf.first, isNot(0));
    }, skip: posix);

    test('strings and returns cross', () async {
      expect(await libc.fn('strlen', C.i64).async('hello'), 5);
      expect(await libc.fn('getenv', C.str).async('DART_TOOLKIT_SURELY_UNSET_VAR'), isNull);
      expect(await libc.fn('atof', C.f64).async('1.5'), 1.5);
    });

    test('concurrent blocking calls run side by side', () async {
      final watch = Stopwatch()..start();
      await Future.wait([for (var i = 0; i < 4; i++) libc.fn('usleep', C.i32).async(200000)]);
      expect(watch.elapsedMilliseconds, lessThan(700), reason: 'four helpers, not one after another');
    }, skip: posix);

    test('an unmodifiable list is not written back', () async {
      final data = Uint8List.fromList([1, 2, 3, 4]).asUnmodifiableView();
      await libc.fn('memset', C.ptr).async(data, 9, data.length);
      expect(data, [1, 2, 3, 4]);
    });

    test("the other isolate's error comes back", () async {
      await expectLater(libc.fn('strlen', C.i64).async([104, 105]), throwsArgumentError);
    });
  });

  group('a compiled probe', () {
    // Shapes libc has no clean example of; built only where a C compiler is.
    Lib? probe;
    String? why;
    setUpAll(() {
      if (Platform.isWindows) return;
      final dir = Directory.systemTemp.createTempSync('ffi_probe');
      final out = '${dir.path}/libprobe.${Platform.isMacOS ? 'dylib' : 'so'}';
      try {
        final cc = Process.runSync('cc', ['-shared', '-fPIC', '-O1', '-o', out, 'test/fixtures/ffi_probe.c']);
        if (cc.exitCode != 0) {
          why = 'cc failed: ${cc.stderr}';
          return;
        }
        probe = Ffi.open(out);
      } on ProcessException {
        why = 'no cc';
      }
    });

    void need() {
      if (probe == null) markTestSkipped(why ?? 'no probe on this platform');
    }

    test('eight integer arguments', () {
      need();
      expect(probe?.call('sum8', C.i64, 1, 2, 3, 4, 5, 6, 7, 8), 87654321);
    });

    test('doubles and integers interleaved', () {
      need();
      expect(probe?.call('mixed', C.f64, 0.5, 2, 3.0, 4), 4320.5);
    });

    test('a float in, a float out', () {
      need();
      expect(probe?.call('halff', C.f32, C.f32(3.0)), 1.5);
    });

    test('a narrow parameter is passed as its key makes it', () {
      need();
      expect(probe?.call('from8', C.i32, C.i8(255)), -1);
      expect(probe?.call('fromu8', C.i32, C.u8(-1)), 255);
    });

    test('a callback reads negative ints with C.i32', () {
      need();
      if (probe case final p?) {
        final cb = Ffi.callback((int a, int b) => C.i32(a) * 10 + C.i32(b));
        addTearDown(cb.close);
        expect(p.call('call2', C.i64, cb, -1, -2), -12);
      }
    });

    test('a callback returning an Owned hands over its address; a throw gives 0', () {
      need();
      if (probe case final p?) {
        final h = libc.own(libc.call('malloc', C.ptr, 16), 'free');
        final give = Ffi.callback(() => h);
        final boom = Ffi.callback(() => throw StateError('boom'));
        addTearDown(() {
          give.close();
          boom.close();
          h.close();
        });
        expect(p.call('call0', C.i64, give), h.ptr.address);
        expect(p.call('call0', C.i64, boom), 0);
      }
    });
  });

  group("the toolkit's own library", () {
    final path = [
      Directory.current.path,
      'native',
      'prebuilt',
      NativeBridge.target,
      NativeBridge.fileName,
    ].join(Platform.pathSeparator);
    final missing = File(path).existsSync() ? null : 'no prebuilt dart_toolkit_native for ${NativeBridge.target}';

    test('tk_digest sha256("abc") through Ffi.open(path)', () {
      final tk = Ffi.open(path);
      final out = Uint8List(64);
      const sha256 = 3;
      final n = tk.call('tk_digest', C.i32, sha256, 'abc', 3, out, out.length);
      expect(n, 32);
      expect(
        out.take(n).map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
    }, skip: missing);

    test('reports the version NativeLib does', () {
      expect(Ffi.open(path).call('tk_version', C.u32), NativeLib.version);
    }, skip: missing);
  });
}
