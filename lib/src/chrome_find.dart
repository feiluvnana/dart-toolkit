/// Where `chrome` finds a browser: Chrome for Testing already in the user
/// cache (`chrome-headless-shell` for headless runs: it starts ~4x faster
/// than a full Chrome), else an installed Chrome or Chromium, else Chrome
/// for Testing downloaded once per machine.
///
/// The download runs in an isolate spawned from `chrome_fetch.dart`, so a
/// chrome script never compiles http and archive at startup.
library;

import 'dart:ffi' show Abi;
import 'dart:io' as io;
import 'dart:isolate';

import 'package:path/path.dart' as p;

import 'cache.dart';
import 'cdp.dart';

/// The cached Chrome for Testing, else an installed Chrome or Chromium,
/// else Chrome for Testing downloaded now.
Future<String> chromeExecutable({required bool headless}) async {
  final cached = _testingPath(headless: headless);
  if (cached != null && io.File(cached.exe).existsSync()) return cached.exe;
  return installedChrome() ?? await testingChrome(headless: headless);
}

/// Where Chrome for Testing lives in the cache for this machine, or null
/// when it has no build for this platform.
({String kind, String platform, String dir, String exe})? _testingPath({required bool headless}) {
  final platform = testingPlatform();
  if (platform == null) return null;
  final kind = headless ? 'chrome-headless-shell' : 'chrome';
  final dir = p.join(userCacheDir(), 'dart_toolkit', 'chrome', '$kind-$platform');
  final exe = p.join(dir, '$kind-$platform', switch ((kind, platform)) {
    ('chrome', 'mac-arm64' || 'mac-x64') => 'Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing',
    (_, 'win64' || 'win32') => '$kind.exe',
    _ => kind,
  });
  return (kind: kind, platform: platform, dir: dir, exe: exe);
}

/// The first installed Chrome or Chromium, or null.
String? installedChrome() {
  final env = io.Platform.environment;
  final List<String> candidates;
  if (io.Platform.isMacOS) {
    candidates = [
      for (final root in ['/Applications', '${env['HOME']}/Applications']) ...[
        '$root/Google Chrome.app/Contents/MacOS/Google Chrome',
        '$root/Chromium.app/Contents/MacOS/Chromium',
      ],
    ];
  } else if (io.Platform.isWindows) {
    candidates = [
      for (final root in [env['PROGRAMFILES'], env['PROGRAMFILES(X86)'], env['LOCALAPPDATA']])
        if (root != null)
          for (final vendor in ['Google\\Chrome', 'Chromium']) '$root\\$vendor\\Application\\chrome.exe',
    ];
  } else {
    candidates = [
      for (final dir in (env['PATH'] ?? '').split(':'))
        if (dir.isNotEmpty)
          for (final name in ['google-chrome', 'google-chrome-stable', 'chromium', 'chromium-browser', 'chrome'])
            '$dir/$name',
    ];
  }
  for (final c in candidates) {
    if (io.File(c).existsSync()) return c;
  }
  return null;
}

/// Chrome for Testing's platform name for this machine, or null.
String? testingPlatform() => switch (Abi.current()) {
  Abi.macosArm64 => 'mac-arm64',
  Abi.macosX64 => 'mac-x64',
  Abi.linuxX64 => 'linux64',
  Abi.windowsX64 => 'win64',
  Abi.windowsIA32 => 'win32',
  _ => null,
};

/// The cached Chrome for Testing (`chrome-headless-shell` when [headless]),
/// downloaded on first use.
Future<String> testingChrome({required bool headless}) async {
  final (:kind, :platform, :dir, :exe) =
      _testingPath(headless: headless) ??
      (throw BrowserException(
        'no Chrome found and no Chrome for Testing build for ${Abi.current()}: '
        'install Chrome or Chromium, or pass path:',
      ));
  if (io.File(exe).existsSync()) return exe;
  io.stderr.writeln('dart_toolkit: downloading $kind for $platform (once per machine)');
  final reply = ReceivePort();
  try {
    final entry = await Isolate.resolvePackageUri(Uri.parse('package:dart_toolkit/src/chrome_fetch.dart'));
    if (entry == null) throw UnsupportedError('no package config');
    await Isolate.spawnUri(
      entry,
      [kind, platform, dir],
      reply.sendPort,
      onError: reply.sendPort,
      onExit: reply.sendPort,
      automaticPackageResolution: true,
    );
  } catch (e) {
    reply.close();
    throw BrowserException(
      'no Chrome found, and Chrome for Testing can only be fetched from a JIT run '
      '(`dart run`) or with Chrome installed: pass path: or install Chrome ($e)',
      cause: e,
    );
  }
  final result = await reply.first;
  reply.close();
  if (result != null || !io.File(exe).existsSync()) {
    throw BrowserException('Chrome for Testing download failed: ${result ?? 'no $exe'}', cause: result);
  }
  return exe;
}
