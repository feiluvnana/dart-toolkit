import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_toolkit/hash.dart';
import 'package:dart_toolkit/src/native.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  final file = NativeBridge.fileOf('native');
  final built = '${Directory.current.path}/native/lib/${NativeBridge.target}/$file';

  /// Why the native library does not load in a fresh process with `DART_TOOLKIT_NATIVE` set to
  /// [override]: the variable is read once, when the library is first asked for.
  Future<String> reason(String override, {String library = 'native'}) async {
    final script = '${tempDir('tk_reason_')}/reason.dart';
    File(script).writeAsStringSync('''
import 'package:dart_toolkit/src/native.dart';

void main() => print((${library == 'torrent' ? 'NativeBridge.torrent' : 'NativeBridge.main'}).reason);
''');
    final r = await Process.run(
      Platform.resolvedExecutable,
      ['--packages=${Directory.current.path}/.dart_tool/package_config.json', script],
      environment: {'DART_TOOLKIT_NATIVE': override},
    );
    expect(r.exitCode, 0, reason: '${r.stderr}');
    return '${r.stdout}'.trim();
  }

  test('the libraries load, and check says so', () async {
    final native = await Native.check();
    expect(native.isAvailable, isTrue, reason: '${native.reason}');
    expect(native.reason, isNull);
    expect(native.missing, isEmpty);
    expect(NativeBridge.main.isLoaded, isTrue);
  });

  test('decodeText reads a legacy charset into the string, in the library\'s own buffer', () {
    // 日本 in Shift_JIS, then ASCII and a byte that is no character.
    final bytes = Uint8List.fromList([0x93, 0xfa, 0x96, 0x7b, 0x61, 0x80]);
    expect(NativeBridge.main.decodeText('shift_jis', bytes), '日本a\u0080');
    expect(NativeBridge.main.decodeText('euc-kr', Uint8List(0)), '');
  });

  test('hash exports NativeException, worded as the error table has it (HSH-1)', () {
    // `hash.dart` alone names it: no import of native.dart is needed to catch one.
    const e = NativeException('hash with sha256', 'boom');
    expect('$e', 'Cannot hash with sha256: boom');
  });

  test('DART_TOOLKIT_NATIVE is the only place looked when set, and a failure says why', () async {
    expect(await reason('/nonexistent/lib.dylib'), allOf(contains('not found: '), contains('nonexistent')));
    // A file that is not a library, rather than the bundled copy loading in its place.
    // Made absolute: the loader would search its own path for a relative name.
    expect(
      await reason('pubspec.yaml'),
      startsWith('${Directory.current.path}${Platform.pathSeparator}pubspec.yaml: '),
    );
  });

  test('DART_TOOLKIT_NATIVE empty is unset, and relative is against the working directory', () async {
    expect(await reason(''), 'null');
    expect(await reason('native/lib/${NativeBridge.target}/$file'), 'null');
  });

  test('DART_TOOLKIT_NATIVE also says where the torrent library is: beside it', () async {
    final dir = tempDir('tk_native_');
    File(built).copySync('$dir/$file');
    expect(await reason('$dir/$file'), 'null');
    expect(
      await reason('$dir/$file', library: 'torrent'),
      contains('DART_TOOLKIT_NATIVE file not found: $dir${Platform.pathSeparator}${NativeBridge.fileOf('torrent')}'),
    );
  });

  test('require hands over the library, and the file name and target are this platform\'s', () {
    expect(NativeBridge.main.require(), isNotNull);
    expect(file, contains('dart_toolkit_native'));
    expect(NativeBridge.target, matches(RegExp(r'^(macos|linux|windows)_(arm64|x64)$')));
  });

  test('the torrent library loads beside the main one, with its own ABI and error slot', () {
    final t = NativeBridge.torrent;
    expect(t.reason, isNull, reason: 'dart_toolkit_torrent did not load: ${t.reason}');
    expect(t.require().lookupFunction<Uint32 Function(), int Function()>('tk_version')(), t.abi);
    expect(
      NativeBridge.main.require().lookupFunction<Uint32 Function(), int Function()>('tk_version')(),
      NativeBridge.main.abi,
    );
    // Two libraries, two heaps: a buffer from one is released by the same one.
    final buf = t.alloc(16);
    t.free(buf, 16);
  });

  test('the source hash ignores the build trees and line endings', () {
    final a = '${tempDir()}', b = '${tempDir()}';
    File('$a/src/lib.rs')
      ..createSync(recursive: true)
      ..writeAsStringSync('fn a() {}\n');
    File('$b/src/lib.rs')
      ..createSync(recursive: true)
      ..writeAsStringSync('fn a() {}\r\n');
    File('$b/target/release/x').createSync(recursive: true);
    File('$b/lib/macos_arm64/x.dylib').createSync(recursive: true);
    expect(NativeBridge.sourceHash(b), NativeBridge.sourceHash(a));
    File('$b/src/lib.rs').writeAsStringSync('fn b() {}\n');
    expect(NativeBridge.sourceHash(b), isNot(NativeBridge.sourceHash(a)));
  });

  group('install', () {
    late String root, dest;
    late NativeHandle handle;
    late List<String> asked;
    late Map<String, List<int>> served;
    late String releases;

    setUp(() async {
      root = '${tempDir('tk_pkg_')}';
      File('$root/native/Cargo.toml')
        ..createSync(recursive: true)
        ..writeAsStringSync('[package]\nname = "x"\n');
      dest = '$root/native/lib/${NativeBridge.target}/$file';
      handle = NativeBridge.of('native', NativeBridge.main.abi, root: root);
      asked = [];
      served = {};
      final (_, url) = await serve((r) async {
        asked.add(r.uri.path);
        final body = served[r.uri.path];
        r.response.statusCode = body == null ? 404 : 200;
        if (body != null) r.response.add(body);
      });
      releases = '${url}releases';
    });

    /// The asset and digest a release of [root]'s sources would publish.
    String asset() =>
        '/releases/native-${NativeBridge.sourceHash('$root/native')}/${NativeBridge.assetOf('native', NativeBridge.target)}';

    void publish({String? digest}) {
      final gz = gzip.encode(File(built).readAsBytesSync());
      served[asset()] = gz;
      served['${asset()}.sha256'] = '${digest ?? Hash.sha256.bytes(gz).hex}  ${asset().split('/').last}\n'.codeUnits;
    }

    /// A `cargo` that copies this package's built library where `--target-dir` says, or runs
    /// [body] instead.
    String cargo([String? body]) {
      final script = '${tempDir('tk_cargo_')}/cargo';
      File(script).writeAsStringSync(
        '#!/bin/sh\nwhile [ \$# -gt 0 ]; do [ "\$1" = --target-dir ] && t=\$2; shift; done\n'
        '${body ?? 'echo "   Compiling x v0.1.0" >&2; /bin/mkdir -p "\$t/release" && /bin/cp "$built" "\$t/release/$file"'}\n',
      );
      Process.runSync('chmod', ['+x', script]);
      return script;
    }

    Future<void> install({String? cargo}) =>
        Task.run('install', (work) => handle.install(work, releases: releases, cargo: cargo ?? '/nonexistent/cargo'));

    test('check reads files only: nothing missing is fetched, and the reason says how to install', () async {
      expect(handle.reason, allOf(contains('not installed'), contains('Native.install()')));
      expect(asked, isEmpty);
    });

    test('it is downloaded from the release named by the hash of its sources, checked by its SHA-256', () async {
      publish();
      final task = Task.run('install', (work) => handle.install(work, releases: releases, cargo: '/nonexistent/cargo'));
      final steps = <String>[];
      task.statuses.listen((s) => s is Running && s.step != null ? steps.add(s.step!) : null);
      await task;
      expect(asked, ['${asset()}.sha256', asset()]);
      expect(steps, contains('downloading dart_toolkit_native'));
      expect(handle.reason, isNull);
      expect(
        Directory('$root/native/lib/${NativeBridge.target}').listSync().map((e) => e.path),
        isNot(contains(anyOf(endsWith('.gz'), endsWith('.tmp')))),
      );
      asked.clear();
      await install();
      expect(asked, isEmpty, reason: 'installed once');
    });

    test('a download that does not match its digest is refused, and cargo builds it (NAT-3)', () async {
      publish(digest: '0' * 64);
      final steps = <String>[];
      final task = Task.run('install', (work) => handle.install(work, releases: releases, cargo: cargo()));
      task.statuses.listen((s) => s is Running && s.step != null ? steps.add(s.step!) : null);
      await task;
      expect(steps, containsAll(['compiling dart_toolkit_native', 'compiling x']));
      expect(handle.reason, isNull);
      expect(Directory('$root/native/target').existsSync(), isFalse, reason: 'the cargo tree it made is deleted');
    });

    test('a release without a published digest is not trusted', () async {
      publish();
      served.remove('${asset()}.sha256');
      await install(cargo: cargo());
      expect(asked, ['${asset()}.sha256'], reason: 'the library itself is never fetched');
      expect(handle.reason, isNull);
    });

    test('with neither a release nor cargo, the error says both', () async {
      await expectLater(
        install(),
        throwsA(
          isA<NativeException>().having(
            (e) => '$e',
            'text',
            allOf(contains('in release native-'), contains('install Rust from https://rustup.rs')),
          ),
        ),
      );
      final failing = cargo('echo "error: linker cc not found" >&2; /bin/mkdir -p "\$t"; exit 101');
      await expectLater(
        install(cargo: failing),
        throwsA(
          isA<NativeException>().having(
            (e) => '$e',
            'text',
            contains('cargo could not build dart_toolkit_native: error: linker cc not found'),
          ),
        ),
      );
      expect(
        Directory('$root/native/target').existsSync(),
        isFalse,
        reason: 'a failed build leaves no cargo tree (NAT-4)',
      );
    });

    test('a library at another ABI is replaced in its place', () async {
      final torrent = '${Directory.current.path}/native/lib/${NativeBridge.target}/${NativeBridge.fileOf('torrent')}';
      File(dest).parent.createSync(recursive: true);
      File(torrent).copySync(dest);
      expect(handle.reason, contains('reported ABI version ${NativeBridge.torrent.abi}'));
      publish();
      await install();
      expect(handle.reason, anyOf(isNull, contains('so the next run loads it')));
    });

    test('a cancel stops cargo and leaves nothing behind', () async {
      final slow = cargo('/bin/mkdir -p "\$t"; exec /bin/sleep 30');
      final task = Task.run('install', (work) => handle.install(work, releases: releases, cargo: slow));
      await task.statuses.firstWhere((s) => s is Running && s.step == 'compiling dart_toolkit_native');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      task.cancel('enough');
      expect(await task.settled, isA<Stopped<Object?, void>>());
      expect(File(dest).existsSync(), isFalse);
    });

    test('a cancel stops what cargo started too, not only cargo', () async {
      final pidFile = '${tempDir('tk_pid_')}/child';
      final spawning = cargo('/bin/mkdir -p "\$t"; /bin/sleep 30 & echo \$! > "$pidFile"; wait');
      final task = Task.run('install', (work) => handle.install(work, releases: releases, cargo: spawning));
      await task.statuses.firstWhere((s) => s is Running && s.step == 'compiling dart_toolkit_native');
      while (!File(pidFile).existsSync() || File(pidFile).readAsStringSync().trim().isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      final child = File(pidFile).readAsStringSync().trim();
      task.cancel('enough');
      expect(await task.settled, isA<Stopped<Object?, void>>());
      expect(Process.runSync('kill', ['-0', child]).exitCode, isNot(0), reason: 'the child is gone with cargo');
    });
  }, testOn: '!windows');
}
