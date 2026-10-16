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

/// The pinned Chrome for Testing. Google publishes no hashes and signs the
/// builds ad hoc only, so each zip's sha256 is recorded here: nothing runs
/// (or loses its quarantine) before its hash checks. Bump all of them
/// together (`curl -sL <url> | shasum -a 256`).
const _version = '155.0.8059.84';
const _sha256 = {
  'chrome mac-arm64': '13b9e98ce56f5ce18e100a009f455c9285f399e7c9dc8a76fdf2f3a9755bb5f2',
  'chrome-headless-shell mac-arm64': '7f111980bcb41e908d0fa3e969a625e7777ff683c1fc43fd7759d05ec3ffe52b',
  'chrome mac-x64': 'd805a173118daa5f6f5cf464500789e1e00022a9a6aed8abfec821ab828fa862',
  'chrome-headless-shell mac-x64': '3c5bf34eb8daa874e8b50edf900eab618b74c1b9596e596340278eeba4ff1ae1',
  'chrome linux64': 'cf0f049892dea22e6a6db26d47ed0d7776b7158edcbec4634086633df8bafcbc',
  'chrome-headless-shell linux64': 'a5d71b91aa996fef00517cd212b2dfb816b43055edefbe727e6fd562d4ae1f9c',
  'chrome win64': '507f2a031441d10c62b5e3d4e863f09ac1198a571c1419976cbd8387f639afde',
  'chrome-headless-shell win64': '5ca590a4968864e219ea25ccd134597ef8898a733a4698c07fc3e8b2c480fef4',
  'chrome win32': '80cd73d2523691d6b7bcb9fc399f97a8499b64def13f37eec502777b83a9f805',
  'chrome-headless-shell win32': '5d37ece0cc400bbe328f30b4a7b5aa3b26157290cf0b1df3850575317b75d14e',
};

/// Where Chrome for Testing lives in the cache for this machine, or null
/// when it has no build for this platform.
({String kind, String platform, String dir, String exe})? _testingPath({required bool headless}) {
  final platform = testingPlatform();
  if (platform == null) return null;
  final kind = headless ? 'chrome-headless-shell' : 'chrome';
  final dir = p.join(userCacheDir(), 'dart_toolkit', 'chrome', _version, '$kind-$platform');
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
/// downloaded on first use: once per process (a memoized future) and one
/// process at a time (a file lock).
Future<String> testingChrome({required bool headless}) {
  return _fetching[headless] ??= _testingChrome(headless: headless).catchError((Object e) {
    _fetching.remove(headless); // a failed download may be retried
    throw e;
  });
}

final _fetching = <bool, Future<String>>{};

Future<String> _testingChrome({required bool headless}) async {
  final (:kind, :platform, :dir, :exe) =
      _testingPath(headless: headless) ??
      (throw BrowserException(
        'no Chrome found and no Chrome for Testing build for ${Abi.current()}: '
        'install Chrome or Chromium, or pass path:',
      ));
  if (io.File(exe).existsSync()) return exe;
  await io.Directory(p.dirname(dir)).create(recursive: true);
  final lock = await io.File('$dir.lock').open(mode: io.FileMode.append);
  try {
    await lock.lock(io.FileLock.blockingExclusive);
    if (io.File(exe).existsSync()) return exe; // another process fetched it
    final String? failed;
    try {
      final url = 'https://storage.googleapis.com/chrome-for-testing-public/$_version/$platform/$kind-$platform.zip';
      failed = await fetchInIsolate('chrome_fetch.dart', [url, _sha256['$kind $platform']!, dir], label: '$kind for $platform');
    } on UnsupportedError catch (e) {
      throw BrowserException(
        'no Chrome found, and Chrome for Testing can only be fetched from a JIT run '
        '(`dart run`) or with Chrome installed: pass path: or install Chrome (${e.message})',
        cause: e,
      );
    }
    if (failed != null || !io.File(exe).existsSync()) {
      throw BrowserException('Chrome for Testing download failed: ${failed ?? 'no $exe'}', cause: failed);
    }
    return exe;
  } finally {
    await lock.close(); // closing releases the lock
  }
}
