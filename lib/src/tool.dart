/// Native tools the toolkit runs (ffmpeg and ffprobe for media, 7-Zip for
/// big or exotic archives): a copy on PATH that has what the call needs,
/// else a build pinned by sha256 and downloaded once into the user cache.
///
/// One process downloads at a time (a file lock), a process asks once (a
/// memoized future), and nothing is run before its hash checks.
library;

import 'dart:async';
import 'dart:ffi' show Abi;
import 'dart:io' as io;

import 'package:path/path.dart' as p;

import 'dart:isolate';

import '../shell.dart';
import 'cache.dart' as cache;
import 'posix.dart' as posix;

/// A tool [tool] can find.
enum Tool { ffmpeg, ffprobe, sevenzip }

/// A download: the archive, its sha256, and where the binary sits inside it
/// (null: the download is the binary).
typedef _Build = ({String url, String sha256, String? member});

const _sevenzipUrl = 'https://github.com/ip7z/7zip/releases/download/26.04';

const _riedl = 'https://ffmpeg.martin-riedl.de/download';
const _gyan = 'https://github.com/GyanD/codexffmpeg/releases/download/9.0.2/ffmpeg-9.0.2-essentials_build.zip';
const _gyanSha = '60f467265b1e312373dbcd92200c2618a74850f98d3d078e94296bb3fa2047ba';
const _sevenzipMac = 'bee04358cbcbc7106273cee0e8d72916db2696c48067a3538c34d8cd6fd16578';
const _sevenzipWin = '256feca8e274e5da655e2a284fabafd9f554365eb164862089dacd4e8276d282'; // 7z only: Windows reads RAR in Dart

/// Pinned builds per ABI: 7-Zip 26.04 (universal on macOS, static `7zzs`
/// on Linux, the 7z-only `7zr.exe` on Windows); ffmpeg 9.0.2 from Martin
/// Riedl's static builds (macOS, Linux) and Gyan's essentials build
/// (Windows; arm64 Windows runs it emulated).
const Map<Abi, Map<Tool, _Build>> _builds = {
  Abi.macosArm64: {
    Tool.sevenzip: (url: '$_sevenzipUrl/7z2604-mac.tar.xz', sha256: _sevenzipMac, member: '7zz'),
    Tool.ffmpeg: (
      url: '$_riedl/macos/arm64/1789931890_9.0.2/ffmpeg.zip',
      sha256: 'c8ed4c4e6978a03c485edbfe4e0a5dc2380f8a30bba5150531b31b094492d924',
      member: 'ffmpeg',
    ),
    Tool.ffprobe: (
      url: '$_riedl/macos/arm64/1789931890_9.0.2/ffprobe.zip',
      sha256: 'fcbe839537485eaee7a7a8bc5cbc0f90d53617e80943e8a5b2e31cb851197ea6',
      member: 'ffprobe',
    ),
  },
  Abi.macosX64: {
    Tool.sevenzip: (url: '$_sevenzipUrl/7z2604-mac.tar.xz', sha256: _sevenzipMac, member: '7zz'),
    Tool.ffmpeg: (
      url: '$_riedl/macos/amd64/1789931006_9.0.2/ffmpeg.zip',
      sha256: '7c6b4125b191cbf773832dc51f424cf2b6bb7da43007d1e066f95909e47cacd4',
      member: 'ffmpeg',
    ),
    Tool.ffprobe: (
      url: '$_riedl/macos/amd64/1789931006_9.0.2/ffprobe.zip',
      sha256: '2322438ed2f6319a691291b247d09c69dcaa3a982460d1f269a7e1af335cfdfd',
      member: 'ffprobe',
    ),
  },
  Abi.linuxX64: {
    Tool.sevenzip: (
      url: '$_sevenzipUrl/7z2604-linux-x64.tar.xz',
      sha256: 'fc0327ba27e89bd086cf426dff17d77de582953cdbbc10a6576540a06853ffcd',
      member: '7zzs',
    ),
    Tool.ffmpeg: (
      url: '$_riedl/linux/amd64/1789931100_9.0.2/ffmpeg.zip',
      sha256: 'fa8ecf4abbd290d98f7d188b8649cc6b391ae209a98452be955a15aab1909d7f',
      member: 'ffmpeg',
    ),
    Tool.ffprobe: (
      url: '$_riedl/linux/amd64/1789931100_9.0.2/ffprobe.zip',
      sha256: '3f428c49070be3d24ec338602b76d412e401ffcb8a5641ef0e729181a232fc32',
      member: 'ffprobe',
    ),
  },
  Abi.linuxArm64: {
    Tool.sevenzip: (
      url: '$_sevenzipUrl/7z2604-linux-arm64.tar.xz',
      sha256: '5b0ac3aa91c1e3499f011d6af69d7f6b4de3ef2f011d9e2ff44c58ebd04aa388',
      member: '7zzs',
    ),
    Tool.ffmpeg: (
      url: '$_riedl/linux/arm64/1789931697_9.0.2/ffmpeg.zip',
      sha256: '93a76ae90db5474eecdf951a729857c64f3de23567228d6a7d5e6e8e3cd1021b',
      member: 'ffmpeg',
    ),
    Tool.ffprobe: (
      url: '$_riedl/linux/arm64/1789931697_9.0.2/ffprobe.zip',
      sha256: 'bcbe80fb741c180083327afaf5434812e006b33cacde2016b9aeaf6936128330',
      member: 'ffprobe',
    ),
  },
  Abi.windowsX64: {
    Tool.sevenzip: (url: '$_sevenzipUrl/7zr.exe', sha256: _sevenzipWin, member: null),
    Tool.ffmpeg: (url: _gyan, sha256: _gyanSha, member: 'ffmpeg-9.0.2-essentials_build/bin/ffmpeg.exe'),
    Tool.ffprobe: (url: _gyan, sha256: _gyanSha, member: 'ffmpeg-9.0.2-essentials_build/bin/ffprobe.exe'),
  },
  Abi.windowsArm64: {
    Tool.sevenzip: (url: '$_sevenzipUrl/7zr.exe', sha256: _sevenzipWin, member: null),
    Tool.ffmpeg: (url: _gyan, sha256: _gyanSha, member: 'ffmpeg-9.0.2-essentials_build/bin/ffmpeg.exe'),
    Tool.ffprobe: (url: _gyan, sha256: _gyanSha, member: 'ffmpeg-9.0.2-essentials_build/bin/ffprobe.exe'),
  },
};

/// The folder [t]'s pinned build lives in: one per version, so a bump never
/// mixes builds.
String _home(Tool t) =>
    p.join(cache.userCacheDir(), 'dart_toolkit', t == Tool.sevenzip ? '7zip-26.04' : 'ffmpeg-9.0.2');

String _exe(Tool t) => switch (t) {
  Tool.sevenzip => io.Platform.isWindows ? '7zr.exe' : '7zz',
  _ => io.Platform.isWindows ? '${t.name}.exe' : t.name,
};

/// Names to look for on PATH.
List<String> _onPath(Tool t) => switch (t) {
  Tool.sevenzip => ['7zz', if (io.Platform.isWindows) '7z'],
  _ => [t.name],
};

final _found = <(Tool, String), Future<String>>{};

/// The path of [t]. [needs] names encoders the call uses (`libwebp`,
/// `libsvtav1`): a PATH copy lacking one is passed over for the pinned
/// build, which has them all.
Future<String> tool(Tool t, {Set<String> needs = const {}}) {
  final key = (t, (needs.toList()..sort()).join(','));
  return _found[key] ??= _locate(t, needs).catchError((Object e) {
    _found.remove(key); // a failed download may be retried
    throw e;
  });
}

Future<String> _locate(Tool t, Set<String> needs) async {
  final pinned = p.join(_home(t), _exe(t));
  if (await io.File(pinned).exists()) return pinned;
  for (final name in _onPath(t)) {
    final onPath = await Shell.which(name);
    if (onPath != null && (needs.isEmpty || (await _encoders(onPath)).containsAll(needs))) return onPath;
  }
  await _download(t, pinned);
  return pinned;
}

/// The encoder names an ffmpeg binary lists.
Future<Set<String>> _encoders(String ffmpeg) async {
  final out = await Shell.run([ffmpeg, '-hide_banner', '-encoders']);
  return {
    for (final line in (await out.text()).split('\n'))
      if (line.length > 8 && line.startsWith(' ') && line[1] != '-') line.substring(8).split(' ').first,
  };
}

Future<void> _download(Tool t, String target) async {
  final build = _builds[Abi.current()]?[t];
  if (build == null) {
    throw UnsupportedError('no pinned ${t.name} for ${Abi.current()}: install ${t.name} on PATH');
  }
  final home = _home(t);
  await io.Directory(home).create(recursive: true);
  // Across processes: one downloads, the rest wait and find the binary.
  final lock = await io.File(p.join(home, '.lock')).open(mode: io.FileMode.append);
  try {
    await lock.lock(io.FileLock.blockingExclusive);
    if (await io.File(target).exists()) return;
    final tmp = await io.Directory(home).createTemp('.dl-');
    try {
      await _fetch(build, tmp.path, _exe(t));
      final exe = p.join(tmp.path, build.member ?? _exe(t));
      if (!io.Platform.isWindows) await posix.chmod(exe, 0x1ed);
      // Windows: one zip holds both tools, so take the sibling too.
      for (final other in Tool.values) {
        final b = _builds[Abi.current()]![other]!;
        final src = p.join(tmp.path, b.member ?? _exe(other));
        final dest = p.join(home, _exe(other));
        if (b.url == build.url && await io.File(src).exists() && !await io.File(dest).exists()) {
          if (!io.Platform.isWindows) await posix.chmod(src, 0x1ed);
          await io.File(src).rename(dest);
        }
      }
    } finally {
      await tmp.delete(recursive: true).catchError((_) => tmp);
    }
  } finally {
    await lock.close(); // closing releases the lock
  }
}

/// Run `tool_fetch.dart` in an isolate spawned by URI: a deferred import
/// still compiles http and archive at startup under `dart run`, this does
/// not. A compiled exe cannot spawn it, so it asks for the tool on PATH.
Future<void> _fetch(_Build build, String dir, String name) async {
  io.stderr.writeln('dart_toolkit: downloading ${p.basename(build.url)} (once per machine)');
  final reply = ReceivePort();
  try {
    final entry = await Isolate.resolvePackageUri(Uri.parse('package:dart_toolkit/src/tool_fetch.dart'));
    if (entry == null) throw UnsupportedError('no package config');
    await Isolate.spawnUri(
      entry,
      [build.url, build.sha256, build.member == null ? 'raw' : 'zip', dir, name],
      reply.sendPort,
      onError: reply.sendPort,
      onExit: reply.sendPort,
      automaticPackageResolution: true,
    );
  } catch (e) {
    reply.close();
    throw UnsupportedError('$name is not on PATH and can only be downloaded from a `dart run` script: install it ($e)');
  }
  final result = await reply.first;
  reply.close();
  if (result != null) throw ContentException('download failed: ${build.url}: $result');
}
