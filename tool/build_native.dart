// The rewritten native libraries (native2 ABI 1), built where the package
// looks for them: `native2/lib/<os>_<arch>/`.
//
//   dart run tool/build_native.dart                  this machine                     (make native)
//   dart run tool/build_native.dart --all            every target it can cross-build  (make native-all)
//   dart run tool/build_native.dart --release        --all, then the GitHub release a first use
//                                                    downloads from                   (make native-release)
//   dart run tool/build_native.dart --copy-to <dir>  this machine's, beside an executable (make bench)
//   dart run tool/build_native.dart --clean          cargo's tree and native2/lib/ gone (make clean)
//
// Plain `dart:` only: this script bootstraps the natives, so it cannot use
// them (no package imports at all). SHA-256 below is the single documented
// exception to "no Dart fallback": without it an unverified download would
// break rule r51.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

/// Every target a release carries, by its `native2/lib/` folder.
const targets = <String, String>{
  'linux_x64': 'x86_64-unknown-linux-gnu',
  'linux_arm64': 'aarch64-unknown-linux-gnu',
  'macos_x64': 'x86_64-apple-darwin',
  'macos_arm64': 'aarch64-apple-darwin',
  'windows_x64': 'x86_64-pc-windows-msvc',
  'windows_arm64': 'aarch64-pc-windows-msvc',
};

/// Every cdylib, by crate name: the file is `dart_toolkit_<crate>`.
const crates = ['native', 'chrome', 'tui', 'torrent'];

/// The ABI each crate reports from `tk_version`.
const abis = {'native': 1, 'chrome': 1, 'tui': 1, 'torrent': 1};

/// Where `make native-release` uploads the libraries: a release per source hash.
const releases = 'https://github.com/feiluvnana/dart-toolkit/releases/download';

String get _nativeDir => '${Directory.current.path}${Platform.pathSeparator}native2';

String _join(String a, String b) =>
    a.endsWith('/') || a.endsWith(Platform.pathSeparator) ? '$a$b' : '$a${Platform.pathSeparator}$b';

String _dirOf(String path) => path.substring(0, path.lastIndexOf(Platform.pathSeparator));

String fileOf(String crate, [String? target]) => switch ((target ?? _target).split('_').first) {
  'macos' => 'libdart_toolkit_$crate.dylib',
  'windows' => 'dart_toolkit_$crate.dll',
  _ => 'libdart_toolkit_$crate.so',
};

String get _target {
  final arch = switch (Abi.current()) {
    Abi.macosArm64 || Abi.linuxArm64 || Abi.windowsArm64 => 'arm64',
    _ => 'x64',
  };
  return '${Platform.operatingSystem}_$arch';
}

/// Library [crate]'s file for [target] (`macos_arm64`) in a release, gzipped.
String assetOf(String crate, String target) => '$target-${fileOf(crate, target)}.gz';

void info(String s) => stdout.writeln(s);
void ok(String s) => stdout.writeln('ok: $s');

Never fail(String s) {
  stderr.writeln('error: $s');
  exit(1);
}

/// Runs [exe] with [args], answering stdout; throws the stderr tail on failure.
Future<String> run(String exe, List<String> args, {String? workdir}) async {
  final r = await Process.run(exe, args, workingDirectory: workdir);
  if (r.exitCode != 0) {
    final lines = '${r.stderr}'.trim().split('\n');
    throw StateError(
      '${[exe, ...args].join(' ')}\n${lines.skip(lines.length > 8 ? lines.length - 8 : 0).join('\n')}'.trim(),
    );
  }
  return '${r.stdout}';
}

Future<bool> has(String command) async {
  for (final dir in (Platform.environment['PATH'] ?? '').split(Platform.isWindows ? ';' : ':')) {
    final exts = Platform.isWindows ? ['.exe', '.cmd', '.bat', ''] : [''];
    for (final ext in exts) {
      if (await File(_join(dir, '$command$ext')).exists()) return true;
    }
  }
  return false;
}

/// [crate] for [folder] into `native2/lib/<folder>/`: the host through cargo,
/// another target through whichever cross tool is here.
Future<bool> buildOne(String folder, String crate) async {
  info('dart_toolkit_$crate for $folder');
  if (folder == _target) {
    try {
      await run('cargo', ['build', '--release', '-p', 'dart_toolkit_$crate'], workdir: _nativeDir);
    } catch (e) {
      stderr.writeln('error: $e');
      return false;
    }
    final built = _join(_join(_join(_nativeDir, 'target'), 'release'), fileOf(crate, folder));
    final out = _join(_join(_join(_nativeDir, 'lib'), folder), fileOf(crate, folder));
    await Directory(_dirOf(out)).create(recursive: true);
    await File(built).copy(out);
    ok(out);
    return true;
  }
  final triple = targets[folder]!;
  if (await has('rustup') && !(await run('rustup', ['target', 'list', '--installed'])).contains(triple)) {
    await run('rustup', ['target', 'add', triple]);
  }
  final windows = triple.contains('windows'), darwin = triple.contains('darwin');
  final args = switch (null) {
    _ when darwin && Platform.isMacOS => ['build'],
    _ when windows && !Platform.isWindows && await has('cargo-xwin') => ['xwin', 'build'],
    _ when !windows && await has('cargo-zigbuild') => ['zigbuild'],
    _ => ['build'],
  };
  try {
    await run('cargo', [...args, '--release', '--target', triple, '-p', 'dart_toolkit_$crate'], workdir: _nativeDir);
  } catch (e) {
    stderr.writeln('error: cargo failed for $folder: $e');
    return false;
  }
  final out = _join(_join(_join(_nativeDir, 'lib'), folder), fileOf(crate, folder));
  await Directory(_dirOf(out)).create(recursive: true);
  await File(_join(_join(_join(_join(_nativeDir, 'target'), triple), 'release'), fileOf(crate, folder))).copy(out);
  ok(out);
  return true;
}

/// Every target, each crate; answers the folders that built both.
Future<List<String>> buildAll() async {
  final built = <String>[];
  for (final folder in targets.keys) {
    var okFolder = true;
    for (final crate in crates) {
      okFolder = await buildOne(folder, crate) && okFolder;
    }
    info('${okFolder ? 'yes' : 'no '} $folder');
    if (okFolder) built.add(folder);
  }
  return built;
}

/// The Rust sources under `native2/`, as 16 hex digits: every file but the build
/// trees (`target/`, `lib/`) and dotfiles, by path, line endings as `\n`, so a
/// Windows checkout hashes as a Mac's. What names a release.
String sourceHash() {
  final root = Directory(_nativeDir).absolute.path;
  final files = <String, File>{};
  for (final e in Directory(root).listSync(recursive: true, followLinks: false)) {
    if (e is! File) continue;
    final rel = e.path.substring(root.length + 1).replaceAll(r'\', '/');
    final parts = rel.split('/');
    if (parts.first == 'target' || parts.first == 'lib') continue;
    if (parts.any((p) => p.startsWith('.') && p != '.cargo')) continue;
    files[rel] = e;
  }
  // FNV-1a, 64 bits: no digest is loaded yet, and this names a build, it guards nothing.
  var h = 0xcbf29ce484222325;
  void add(int byte) => h = (h ^ byte) * 0x100000001b3;
  for (final rel in files.keys.toList()..sort()) {
    utf8.encode(rel).forEach(add);
    add(0);
    for (final b in files[rel]!.readAsBytesSync()) {
      if (b != 13) add(b);
    }
    add(0);
  }
  String hex(int v) => v.toRadixString(16).padLeft(8, '0');
  return '${hex(h >>> 32)}${hex(h & 0xffffffff)}';
}

/// SHA-256 of [data] in hex. Bootstrap-only pure Dart (see the header): the
/// release flow checks downloads against their published hashes before any
/// native library exists to do it.
String sha256Hex(List<int> data) {
  const k = [
    0x428a2f98,
    0x71374491,
    0xb5c0fbcf,
    0xe9b5dba5,
    0x3956c25b,
    0x59f111f1,
    0x923f82a4,
    0xab1c5ed5,
    0xd807aa98,
    0x12835b01,
    0x243185be,
    0x550c7dc3,
    0x72be5d74,
    0x80deb1fe,
    0x9bdc06a7,
    0xc19bf174,
    0xe49b69c1,
    0xefbe4786,
    0x0fc19dc6,
    0x240ca1cc,
    0x2de92c6f,
    0x4a7484aa,
    0x5cb0a9dc,
    0x76f988da,
    0x983e5152,
    0xa831c66d,
    0xb00327c8,
    0xbf597fc7,
    0xc6e00bf3,
    0xd5a79147,
    0x06ca6351,
    0x14292967,
    0x27b70a85,
    0x2e1b2138,
    0x4d2c6dfc,
    0x53380d13,
    0x650a7354,
    0x766a0abb,
    0x81c2c92e,
    0x92722c85,
    0xa2bfe8a1,
    0xa81a664b,
    0xc24b8b70,
    0xc76c51a3,
    0xd192e819,
    0xd6990624,
    0xf40e3585,
    0x106aa070,
    0x19a4c116,
    0x1e376c08,
    0x2748774c,
    0x34b0bcb5,
    0x391c0cb3,
    0x4ed8aa4a,
    0x5b9cca4f,
    0x682e6ff3,
    0x748f82ee,
    0x78a5636f,
    0x84c87814,
    0x8cc70208,
    0x90befffa,
    0xa4506ceb,
    0xbef9a3f7,
    0xc67178f2,
  ];
  int rotr(int x, int c) => ((x >>> c) | (x << (32 - c))) & 0xFFFFFFFF;
  int add32(int a, int b) => (a + b) & 0xFFFFFFFF;
  final msg = BytesBuilder(copy: true)..add(data);
  final bitLen = data.length * 8;
  msg.addByte(0x80);
  while (msg.length % 64 != 56) {
    msg.addByte(0);
  }
  for (var i = 7; i >= 0; i--) {
    msg.addByte((bitLen >>> (8 * i)) & 0xFF);
  }
  final bytes = msg.takeBytes();
  final h = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
  final w = List<int>.filled(64, 0);
  for (var off = 0; off < bytes.length; off += 64) {
    for (var i = 0; i < 16; i++) {
      w[i] =
          (bytes[off + i * 4] << 24) |
          (bytes[off + i * 4 + 1] << 16) |
          (bytes[off + i * 4 + 2] << 8) |
          bytes[off + i * 4 + 3];
    }
    for (var i = 16; i < 64; i++) {
      final s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >>> 3);
      final s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >>> 10);
      w[i] = add32(add32(w[i - 16], s0), add32(w[i - 7], s1));
    }
    var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
    for (var i = 0; i < 64; i++) {
      final s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
      final ch = (e & f) ^ (~e & g);
      final t1 = add32(add32(add32(add32(hh, s1), ch), k[i]), w[i]);
      final s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final t2 = add32(s0, maj);
      hh = g;
      g = f;
      f = e;
      e = add32(d, t1);
      d = c;
      c = b;
      b = a;
      a = add32(t1, t2);
    }
    h[0] = add32(h[0], a);
    h[1] = add32(h[1], b);
    h[2] = add32(h[2], c);
    h[3] = add32(h[3], d);
    h[4] = add32(h[4], e);
    h[5] = add32(h[5], f);
    h[6] = add32(h[6], g);
    h[7] = add32(h[7], hh);
  }
  final sb = StringBuffer();
  for (final v in h) {
    sb.write((v & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0'));
  }
  return sb.toString();
}

int _abiOf(String path) {
  try {
    final lib = DynamicLibrary.open(path);
    final abi = lib.lookupFunction<Uint32 Function(), int Function()>('tk_version')();
    lib.close();
    return abi;
  } catch (_) {
    return -1;
  }
}

/// The release a first use downloads from: `native-<hash of native2/>`, one gzipped asset per
/// target and crate, each with its `.sha256` beside it, which a first use checks the download
/// against. The sources must be committed, so the hash is what a checkout computes.
Future<void> release() async {
  final dirty = await run('git', ['status', '--porcelain', '--', 'native2']);
  if (dirty.trim().isNotEmpty) {
    fail('native2/ has uncommitted changes; commit them first, so a checkout hashes the same');
  }
  final built = await buildAll();
  for (final crate in crates) {
    final lib = _join(_join(_join(_nativeDir, 'lib'), _target), fileOf(crate));
    final abi = _abiOf(lib);
    if (abi != abis[crate]) fail('dart_toolkit_$crate reports ABI $abi, expected ${abis[crate]}');
  }
  final tag = 'native-${sourceHash()}';
  final staging = Directory(_join(_join(Directory.current.path, '.dart_tool'), 'native-release'));
  await staging.create(recursive: true);
  final assets = <String>[];
  for (final folder in built) {
    for (final crate in crates) {
      final asset = File(_join(staging.path, assetOf(crate, folder)));
      final packed = gzip.encode(
        await File(_join(_join(_join(_nativeDir, 'lib'), folder), fileOf(crate, folder))).readAsBytes(),
      );
      await asset.writeAsBytes(packed);
      final digest = File('${asset.path}.sha256');
      await digest.writeAsString('${sha256Hex(packed)}\n');
      assets.addAll([asset.path, digest.path]);
    }
  }
  bool exists;
  try {
    await run('gh', ['release', 'view', tag]);
    exists = true;
  } catch (_) {
    exists = false;
  }
  await run(
    'gh',
    exists
        ? ['release', 'upload', tag, ...assets, '--clobber']
        : [
            'release',
            'create',
            tag,
            ...assets,
            '--title',
            tag,
            '--latest=false',
            '--notes',
            'The native libraries for the Rust sources hashing to ${tag.substring(7)}; '
                'dart_toolkit downloads its platform\'s on first use.',
          ],
  );
  final missing = targets.keys.where((f) => !built.contains(f)).toList();
  ok('$tag: ${built.join(', ')}');
  if (missing.isNotEmpty) {
    stdout.writeln('warn: not in the release, so compiled on first use there: ${missing.join(', ')}');
  }
}

void usage() {
  stdout.writeln('''Build the native libraries into native2/lib/<os>_<arch>/.

  dart run tool/build_native.dart                  this machine
  dart run tool/build_native.dart --all            every target it can cross-build
  dart run tool/build_native.dart --release        --all, then the GitHub release a first use downloads
  dart run tool/build_native.dart --copy-to <dir>  this machine's libraries into a folder, beside an executable
  dart run tool/build_native.dart --clean          cargo's tree and native2/lib/ gone''');
}

Future<void> main(List<String> args) async {
  var all = false, rel = false, clean = false, copyTo = '';
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--all':
        all = true;
      case '--release':
        rel = true;
      case '--clean':
        clean = true;
      case '--copy-to':
        if (++i >= args.length) fail('--copy-to needs a folder');
        copyTo = args[i];
      case '--help' || '-h':
        usage();
        return;
      default:
        fail('unknown flag ${args[i]} (see --help)');
    }
  }
  if (clean) {
    try {
      await run('cargo', ['clean'], workdir: _nativeDir);
    } catch (e) {
      stderr.writeln('warn: $e');
    }
    final lib = Directory(_join(_nativeDir, 'lib'));
    if (await lib.exists()) await lib.delete(recursive: true);
    return;
  }
  if (rel) {
    await release();
    return;
  }
  if (all) {
    if ((await buildAll()).length < targets.length) exit(1);
    return;
  }
  for (final crate in crates) {
    if (!await buildOne(_target, crate)) exit(1);
  }
  if (copyTo.isNotEmpty) {
    await Directory(copyTo).create(recursive: true);
    for (final crate in crates) {
      await File(_join(_join(_join(_nativeDir, 'lib'), _target), fileOf(crate))).copy(_join(copyTo, fileOf(crate)));
    }
  }
}
