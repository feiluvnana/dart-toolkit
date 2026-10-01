// Build the native library `dart_toolkit_native` into `native/prebuilt/<os>_<arch>/`.
//
// Usage:
//   dart run tool/native.dart                 # build for this machine
//   dart run tool/native.dart --target=<tgt>  # build for a specific target (alias or Rust triple)
//   dart run tool/native.dart --all           # build for all supported platforms
//   dart run tool/native.dart --clean         # cargo clean before building
//   dart run tool/native.dart --clean-only    # only cargo clean
//   dart run tool/native.dart --list          # list supported targets
library;

import 'dart:ffi';
import 'dart:io';

import 'package:dart_toolkit/dart_toolkit.dart';

/// All target platforms supported by dart_toolkit.
const allTargets = <String, String>{
  'linux_x64': 'x86_64-unknown-linux-gnu',
  'linux_arm64': 'aarch64-unknown-linux-gnu',
  'macos_x64': 'x86_64-apple-darwin',
  'macos_arm64': 'aarch64-apple-darwin',
  'windows_x64': 'x86_64-pc-windows-msvc',
  'windows_arm64': 'aarch64-pc-windows-msvc',
};

String get hostTarget {
  final os = Platform.operatingSystem;
  final arch = switch (Abi.current()) {
    Abi.macosArm64 || Abi.linuxArm64 || Abi.windowsArm64 => 'arm64',
    _ => 'x64',
  };
  return '${os}_$arch';
}

String targetFolderOf(String rustTarget) {
  if (allTargets.containsKey(rustTarget)) {
    return rustTarget;
  }
  for (final entry in allTargets.entries) {
    if (entry.value == rustTarget) return entry.key;
  }

  final lower = rustTarget.toLowerCase();
  final os = switch (lower) {
    _ when lower.contains('darwin') || lower.contains('macos') || lower.contains('apple') => 'macos',
    _ when lower.contains('windows') || lower.contains('msvc') => 'windows',
    _ => 'linux',
  };
  final arch = lower.contains('aarch64') || lower.contains('arm64') ? 'arm64' : 'x64';
  return '${os}_$arch';
}

String libraryNameOf(String targetFolder) {
  if (targetFolder.startsWith('macos')) return 'libdart_toolkit_native.dylib';
  if (targetFolder.startsWith('windows')) return 'dart_toolkit_native.dll';
  return 'libdart_toolkit_native.so';
}

Future<bool> _hasCommand(String name) async => await which(name) != null;

Future<void> _ensureRustTarget(String rustTarget) async {
  if (!await _hasCommand('rustup')) return;
  final res = await run('rustup target list --installed', quiet: true);
  if (res.isOk) {
    final installed = res.stdout.split(RegExp(r'\r?\n')).map((e) => e.trim()).where((e) => e.isNotEmpty).toSet();
    if (!installed.contains(rustTarget)) {
      Console.info('  Installing target $rustTarget via rustup...');
      final add = await run('rustup target add $rustTarget', quiet: true);
      if (!add.isOk) {
        Console.warn('  Warning: Could not install target $rustTarget: ${add.stderr}');
      }
    }
  }
}

Future<bool> buildOne(String? targetInput, {bool clean = false, bool verbose = true}) async {
  final currentHost = hostTarget;
  final folder = targetInput == null ? currentHost : targetFolderOf(targetInput);
  final rustTarget = targetInput == null ? null : (allTargets[targetInput] ?? targetInput);
  final libName = libraryNameOf(folder);
  final isHostBuild = rustTarget == null || folder == currentHost;

  if (verbose) {
    Console.info('Building for $folder${rustTarget != null ? ' ($rustTarget)' : ''}...');
  }

  final nativeDir = Path.current / 'native';

  if (clean) {
    await run('cargo clean', workdir: nativeDir, quiet: true);
  }

  var executable = 'cargo';
  final args = <String>[];

  if (!isHostBuild) {
    await _ensureRustTarget(rustTarget);

    final isDarwin = rustTarget.contains('darwin') || rustTarget.contains('apple');
    final isWindows = rustTarget.contains('windows') || rustTarget.contains('msvc');

    if (isDarwin && Platform.isMacOS) {
      args.addAll(['build', '--release', '--target', rustTarget]);
    } else if (await _hasCommand('cross')) {
      executable = 'cross';
      args.addAll(['build', '--release', '--target', rustTarget]);
    } else if (isWindows && !Platform.isWindows && await _hasCommand('cargo-xwin')) {
      executable = 'cargo';
      args.addAll(['xwin', 'build', '--release', '--target', rustTarget]);
    } else if (await _hasCommand('cargo-zigbuild')) {
      executable = 'cargo';
      final actualTarget = isWindows && rustTarget.endsWith('-msvc')
          ? rustTarget.replaceAll('-msvc', '-gnu')
          : rustTarget;
      args.addAll(['zigbuild', '--release', '--target', actualTarget]);
    } else {
      args.addAll(['build', '--release', '--target', rustTarget]);
    }
  } else {
    args.addAll(['build', '--release']);
    if (rustTarget != null) {
      await _ensureRustTarget(rustTarget);
      args.addAll(['--target', rustTarget]);
    }
  }

  final result = await run(executable, args: args, workdir: nativeDir, quiet: true);

  if (!result.isOk) {
    Console.error('Build failed for $folder:');
    if (result.stdout.trim().isNotEmpty) Console.writeln(result.stdout);
    if (result.stderr.trim().isNotEmpty) Console.writeln(result.stderr);
    if (!isHostBuild) {
      Console.info(
        'Tip: Cross-compiling for $folder may require cross tools:\n'
        '  - cargo install cargo-zigbuild (with zig installed)\n'
        '  - cargo install cross (with Docker)\n'
        '  - cargo install cargo-xwin (for Windows MSVC targets)',
      );
    }
    return false;
  }

  // Find produced artifact
  final candidates = [
    if (rustTarget != null) nativeDir / 'target' / rustTarget / 'release' / libName,
    if (rustTarget != null && rustTarget.endsWith('-msvc'))
      nativeDir / 'target' / rustTarget.replaceAll('-msvc', '-gnu') / 'release' / libName,
    nativeDir / 'target' / 'release' / libName,
  ];

  Path? source;
  for (final c in candidates) {
    if (c.existsSync()) {
      source = c;
      break;
    }
  }

  if (source == null) {
    Console.error('Built library not found in: ${candidates.map((c) => c.path).join(', ')}');
    return false;
  }

  final destDir = nativeDir / 'prebuilt' / folder;
  if (!destDir.existsSync()) {
    destDir.mkdirSync(recursive: true);
  }
  final destFile = destDir / libName;
  try {
    if (destFile.existsSync()) {
      destFile.deleteSync();
    }
    source.asFile.copySync(destFile.path);
  } on FileSystemException catch (e) {
    Console.error(
      'Error writing to ${destFile.path}: ${e.message}\n'
      'The file may be in use by a running Dart process (such as an active test or application).',
    );
    return false;
  }

  final sizeKb = ((await destFile.size()) / 1024).toStringAsFixed(1);
  Console.info('  -> ${destFile.path} ($sizeKb KB)');
  return true;
}

final optTarget = Opt.text('target', 'Build for a specific target (alias or Rust triple)');
final optAll = Opt.flag('all', 'Build for all supported platforms');
final optClean = Opt.flag('clean', 'Cargo clean before building');
final optCleanOnly = Opt.flag('clean-only', 'Only cargo clean');
final optList = Opt.flag('list', 'List supported targets');

void main(List<String> args) => Cli(
  description: 'Build the native library dart_toolkit_native into native/prebuilt/<os>_<arch>/.',
  values: [optTarget, optAll, optClean, optCleanOnly, optList],
  handler: (ctx) async {
    final all = ctx(optAll);
    final clean = ctx(optClean);
    final cleanOnly = ctx(optCleanOnly);
    final listTargets = ctx(optList);

    if (listTargets) {
      final rows = [
        for (final entry in allTargets.entries) [entry.key, entry.value, entry.key == hostTarget ? 'yes' : 'no'],
      ];
      Table.cells(['target', 'rust triple', 'host'], rows).show();
      return;
    }

    final nativeDir = Path.current / 'native';

    if (cleanOnly) {
      Console.info('Cleaning native build cache...');
      final res = await run('cargo clean', workdir: nativeDir, quiet: true);
      if (!res.isOk) {
        Console.error('cargo clean failed: ${res.stderr}');
        await Lifecycle.exit(1);
      } else {
        Console.info('Clean complete.');
      }
      return;
    }

    final specificTarget = ctx(optTarget);

    if (all) {
      Console.info('Building native library for all platforms...');
      final results = <String, bool>{};
      for (final MapEntry(key: folder, value: rustTarget) in allTargets.entries) {
        Console.info('\n[$folder]');
        final ok = await buildOne(rustTarget, clean: false);
        results[folder] = ok;
      }
      final rows = [
        for (final MapEntry(key: folder, value: ok) in results.entries) [folder, ok ? 'OK' : 'FAILED / SKIPPED'],
      ];
      Console.info('\nSummary:');
      Table.cells(['platform', 'status'], rows).show();
      final allOk = results.values.every((v) => v);
      if (!allOk) await Lifecycle.exit(1);
    } else if (specificTarget != null) {
      final ok = await buildOne(specificTarget, clean: clean);
      if (!ok) await Lifecycle.exit(1);
    } else {
      final ok = await buildOne(null, clean: clean);
      if (!ok) await Lifecycle.exit(1);
    }
  },
).run(args);
