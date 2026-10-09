// The native libraries `dart_toolkit_native` and `dart_toolkit_torrent`, built where the package
// looks for them: `native/lib/<os>_<arch>/`.
//
//   dart run tool/build_native.dart                  this machine                     (make native)
//   dart run tool/build_native.dart --all            every target it can cross-build  (make native-all)
//   dart run tool/build_native.dart --release        --all, then the GitHub release a first use
//                                                    downloads from                   (make native-release)
//   dart run tool/build_native.dart --copy-to <dir>  this machine's, beside an executable (make bench)
//   dart run tool/build_native.dart --clean          cargo's tree and native/lib/ gone (make clean)
library;

import 'dart:ffi';
import 'dart:io';

import 'package:dart_toolkit/cli.dart';
import 'package:dart_toolkit/collection.dart';
import 'package:dart_toolkit/hash.dart';
import 'package:dart_toolkit/path.dart';
import 'package:dart_toolkit/process.dart';
import 'package:dart_toolkit/src/native.dart';

/// Every target a release carries, by its `native/lib/` folder.
const targets = <String, String>{
  'linux_x64': 'x86_64-unknown-linux-gnu',
  'linux_arm64': 'aarch64-unknown-linux-gnu',
  'macos_x64': 'x86_64-apple-darwin',
  'macos_arm64': 'aarch64-apple-darwin',
  'windows_x64': 'x86_64-pc-windows-msvc',
  'windows_arm64': 'aarch64-pc-windows-msvc',
};

const crates = ['native', 'torrent'];

final nativeDir = Path.cwd / 'native';

Path libOf(String folder, String crate) => nativeDir / 'lib' / folder / NativeBridge.fileOf(crate, folder);

NativeHandle handleOf(String crate) => crate == 'native' ? NativeBridge.main : NativeBridge.torrent;

Future<bool> has(String command) async => await (() => Shell.which(command)).orNull != null;

/// [command]'s stderr tail when it fails, else `null`.
Future<String?> failure(Run command) async => switch (await command.settled) {
  Failed(error: ShellException(:final result)) => result.stderr,
  Failed(:final error) => '$error',
  _ => null,
};

/// [crate] for [folder] into `native/lib/<folder>/`: the host through the package's own build,
/// another target through whichever cross tool is here.
Future<bool> buildOne(String folder, String crate) async {
  Console.info('dart_toolkit_$crate for $folder');
  if (folder == NativeBridge.target) {
    final error = handleOf(crate).build();
    if (error != null) Console.error(error);
    return error == null;
  }
  final triple = targets[folder]!;
  if (await has('rustup') && !(await Shell.run('rustup target list --installed').lines).contains(triple)) {
    await Shell.run('rustup target add $triple').settled;
  }
  final windows = triple.contains('windows'), darwin = triple.contains('darwin');
  final args = switch (null) {
    _ when darwin && Platform.isMacOS => ['build'],
    _ when windows && !Platform.isWindows && await has('cargo-xwin') => ['xwin', 'build'],
    _ when !windows && await has('cargo-zigbuild') => ['zigbuild'],
    _ => ['build'],
  };
  final error = await failure(
    Shell.run(
      'cargo',
      args: [...args, '--release', '--target', triple, '-p', 'dart_toolkit_$crate'],
      workdir: nativeDir,
    ),
  );
  if (error != null) {
    final lines = error.trim().split('\n');
    Console.error('cargo failed for $folder: ${lines.skip(lines.length > 8 ? lines.length - 8 : 0).join('\n')}');
    return false;
  }
  final out = libOf(folder, crate);
  await (nativeDir / 'target' / triple / 'release' / out.name).copy(to: out, conflict: Conflict.overwrite);
  Console.ok('$out (${(await out.size()).humanBytes})');
  return true;
}

/// Every target, each crate; answers the folders that built both.
Future<List<String>> buildAll() async {
  final built = <String>[];
  for (final folder in targets.keys) {
    var ok = true;
    for (final crate in crates) {
      ok = await buildOne(folder, crate) && ok;
    }
    if (ok) built.add(folder);
  }
  await Table.rows([
    for (final f in targets.keys) {'target': f, 'built': built.contains(f) ? 'yes' : 'no'},
  ]).show();
  return built;
}

/// The release a first use downloads from: `native-<hash of native/>`, one gzipped asset per
/// target and crate, each with its `.sha256` beside it, which a first use checks the download
/// against. The sources must be committed, so the hash is what a checkout computes.
Future<void> release() async {
  final dirty = await Shell.run('git', args: ['status', '--porcelain', '--', 'native']).text;
  if (dirty.trim().isNotEmpty) {
    Console.exit('native/ has uncommitted changes; commit them first, so a checkout hashes the same');
  }
  final built = await buildAll();
  for (final crate in crates) {
    final lib = DynamicLibrary.open(libOf(NativeBridge.target, crate));
    final abi = lib.lookupFunction<Uint32 Function(), int Function()>('tk_version')();
    if (abi != handleOf(crate).abi) {
      Console.exit('dart_toolkit_$crate reports ABI $abi, expected ${handleOf(crate).abi}');
    }
  }
  final tag = 'native-${NativeBridge.sourceHash(nativeDir.path)}';
  final staging = Path.cwd / '.dart_tool' / 'native-release';
  await staging.mkdir();
  final assets = <String>[];
  for (final folder in built) {
    for (final crate in crates) {
      final asset = staging / NativeBridge.assetOf(crate, folder);
      final packed = gzip.encode(await libOf(folder, crate).readBytes());
      await asset.writeBytes(packed);
      final digest = Path('$asset.sha256');
      await digest.writeText('${Hash.sha256.bytes(packed).hex}\n');
      assets.addAll([asset, digest]);
    }
  }
  final exists = await Shell.run('gh', args: ['release', 'view', tag]).isOk;
  await Shell.run(
    'gh',
    args: exists
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
  Console.ok('$tag: ${built.join(', ')}');
  if (missing.isNotEmpty) Console.warn('not in the release, so compiled on first use there: ${missing.join(', ')}');
}

final optAll = Option.flag('all', 'Every target this machine can cross-build');
final optRelease = Option.flag('release', '--all, then upload them as the GitHub release a first use downloads');
final optCopyTo = Option.of<String>('copy-to', "This machine's libraries into a folder, beside an executable");
final optClean = Option.flag('clean', "Remove cargo's tree and native/lib/");

void main(List<String> args) => Cli(
  'Build the native libraries into native/lib/<os>_<arch>/.',
  values: [optAll, optRelease, optCopyTo, optClean],
  handler: (ctx) async {
    if (ctx(optClean)) {
      await Shell.run('cargo', args: ['clean'], workdir: nativeDir).settled;
      if (await (nativeDir / 'lib').exists()) await (nativeDir / 'lib').delete(recursive: true);
      return;
    }
    if (ctx(optRelease)) return release();
    if (ctx(optAll)) {
      if ((await buildAll()).length < targets.length) Console.exit(null, code: 1);
      return;
    }
    for (final crate in crates) {
      if (!await buildOne(NativeBridge.target, crate)) Console.exit(null, code: 1);
    }
    if (ctx(optCopyTo) case final dir?) {
      await Path(dir).mkdir();
      for (final crate in crates) {
        final lib = libOf(NativeBridge.target, crate);
        await lib.copy(into: dir, conflict: Conflict.overwrite);
      }
    }
  },
).run(args);
