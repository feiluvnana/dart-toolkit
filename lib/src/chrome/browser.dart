part of '../../chrome.dart';

/// Scheme, host and port: the origin a credential is bound to.
String _origin(Uri? url) => url == null ? '' : '${url.scheme}://${url.host.toLowerCase()}:${url.port}';

/// [a] and [b] joined by the platform's separator.
String _join(String a, String b) =>
    a.endsWith('/') || a.endsWith(Platform.pathSeparator) ? '$a$b' : '$a${Platform.pathSeparator}$b';

/// The file at [from] put at [to] in one step: renamed (with the Windows retry), or copied
/// beside [to] and renamed over it when they are on two filesystems.
Future<void> _place(String from, String to) async {
  try {
    await FileBridge.rename(File(from), to);
    return;
  } on FileSystemException {
    // Another filesystem: copied beside the target first, so it appears whole.
  }
  final beside = '$to.${FileBridge.token()}.tmp';
  try {
    await File(from).copy(beside);
    await FileBridge.rename(File(beside), to);
  } catch (_) {
    await File(beside).delete().catchError((Object _) => File(beside)); // best-effort: a stray copy
    rethrow;
  }
  await File(from).delete().catchError((Object _) => File(from)); // best-effort: the landing is erased on close
}

/// A site's suggested name as one safe file name (`HttpBridge.fileName`): Chrome sanitises it
/// too, but the remote host chooses it.
String _fileName(String suggested) {
  final name = HttpBridge.fileName(suggested.split(RegExp(r'[/\\]')).last);
  return name.isEmpty ? 'download' : name;
}

/// Features a fresh profile would use to fetch ~40 MB of models and services in its first minute,
/// and the preconnects to the search engine every navigation makes, through the proxies too.
const _quiet = [
  'PreconnectToSearch',
  'Translate',
  'MediaRouter',
  'OptimizationGuideModelDownloading',
  'OptimizationHintsFetching',
  'OptimizationTargetPrediction',
  'OptimizationHints',
];

/// The `sh` a launched Chrome runs under so it cannot outlive this program:
/// `sh -c _reaper <name> <scratch> <chrome> <args…>`.
///
/// Its stdin is a pipe only this process holds, so EOF arrives however this process ends,
/// `kill -9` included. Then `SIGTERM` to the browser alone (so it writes its cookies; its
/// network process signalled too would die with them unwritten), and `SIGKILL` to the group
/// five seconds later. However Chrome ends, the shell erases `<scratch>` once its helpers are
/// gone too, and exits with Chrome's status, which is how [_activePort] sees a browser that
/// died starting. It traps ^C because a shell killed by one would leave its cleanup undone.
const _reaper = r"""
exec 3<&0 </dev/null >/dev/null 2>&1
trap : INT TERM HUP
set -m
scratch=$1
shift
"$@" 3<&- &
chrome=$!
(
  trap - INT TERM HUP
  cat <&3
  sleep 2
  kill -TERM $chrome
  sleep 5
  kill -KILL -- -$chrome || kill -KILL $chrome
) &
watcher=$!
exec 3<&-
wait $chrome
status=$?
# A trapped signal ends `wait` early: wait again until Chrome itself is gone.
while kill -0 $chrome 2>/dev/null; do
  wait $chrome
  status=$?
done
kill -KILL -- -$watcher || kill -KILL $watcher
# Its helpers outlive it by a moment, the network service still writing cookies: the erase
# waits for its group to empty, and tries again for one that left a file behind it.
for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 -- -$chrome 2>/dev/null || break; sleep 0.2; done
kill -KILL -- -$chrome 2>/dev/null
for _ in 1 2 3; do rm -rf "$scratch" && break; sleep 1; done
exit $status
""";

/// Whether a launched Chrome runs under [_reaper]: wherever there is a POSIX `sh`.
final _reaps = !Platform.isWindows;

/// Stops a launched browser: by closing the [_reaper]'s pipe (which gives Chrome 5 s, so this
/// gives it 10), else by signal; `SIGKILL` when it will not go.
Future<void> _stop(Process process) async {
  // Closing stdin is best-effort: Chrome may have exited already.
  if (_reaps) {
    await process.stdin.close().catchError((Object _) {}); // best-effort
  }
  try {
    await process.exitCode.timeout(const Duration(seconds: 5));
    return;
  } on TimeoutException {
    // Chrome did not exit gracefully
    process.kill();
  }
  await process.exitCode.timeout(
    const Duration(seconds: 5),
    onTimeout: () => process.kill(ProcessSignal.sigkill) ? -9 : 0,
  );
}

/// Whether the DevTools cookie [c] goes to [url]: a leading dot on its domain takes subdomains.
bool _sendsTo(Map<String, Object?> c, Uri url) {
  final named = (c['domain'] as String? ?? '').toLowerCase();
  return HttpBridge.sendsTo(
    url,
    domain: named.startsWith('.') ? named.substring(1) : named,
    path: c['path'] as String? ?? '/',
    secure: c['secure'] == true,
    hostOnly: !named.startsWith('.'),
  );
}

/// Headers Chrome sets itself; sending them corrupts the render.
const _unsafe = {'host', 'connection', 'content-length', 'accept-encoding', 'user-agent', 'upgrade', 'keep-alive'};

List<String> get _chromes {
  final local = Env.get<String?>('LOCALAPPDATA');
  return [
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    '/Applications/Chromium.app/Contents/MacOS/Chromium',
    '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
    '/usr/bin/google-chrome',
    '/usr/bin/google-chrome-stable',
    '/usr/bin/chromium',
    '/usr/bin/chromium-browser',
    '/snap/bin/chromium',
    r'C:\Program Files\Google\Chrome\Application\chrome.exe',
    r'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe',
    if (local != null) '$local\\Google\\Chrome\\Application\\chrome.exe',
    r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
    r'C:\Program Files\Microsoft\Edge\Application\msedge.exe',
    if (local != null) '$local\\Microsoft\\Edge\\Application\\msedge.exe',
  ];
}

/// The browser's websocket endpoint on [host]:[port], or `null` when no DevTools answers.
Future<Uri?> _devtools(String host, int port) async {
  final probe = IoClient();
  try {
    final res = await probe.send(Request('GET', Uri.parse('http://$host:$port/json/version'))).then((r) => r.read());
    return res.isOk ? Uri.tryParse(res.json['webSocketDebuggerUrl'].to<String>()) : null;
  } on Exception catch (_) {
    return null; // nothing listening there, or not a browser
  } finally {
    await probe.close();
  }
}

/// [executable], else `DART_TOOLKIT_CHROME`, else the first of [_chromes] installed; none is a
/// [MissingException].
String _binary(String? executable) {
  final path = executable ?? Env.get<String?>('DART_TOOLKIT_CHROME');
  if (path != null && path.isNotEmpty) return path;
  for (final candidate in _chromes) {
    if (File(candidate).existsSync()) return candidate;
  }
  throw const MissingException('chrome', where: 'DART_TOOLKIT_CHROME');
}

/// Who holds [profile] by Chrome's `SingletonLock` (a symlink to `<host>-<pid>`), or `null`.
/// Read, never removed: a live browser's lock is not ours to break.
Future<String?> _heldBy(Directory profile) async {
  if (Platform.isWindows) {
    final lockfile = File('${profile.path}/lockfile');
    try {
      if (!await lockfile.exists()) return null;
      final raf = await lockfile.open(mode: FileMode.write);
      await raf.close();
      return null;
    } on FileSystemException catch (e) {
      if (e.osError?.errorCode == 32) return 'another browser';
      return null;
    } catch (_) {
      // unable to check lockfile
      return null;
    }
  }
  final lock = Link('${profile.path}/SingletonLock');
  try {
    if (!await lock.exists()) return null;
    final pid = int.tryParse((await lock.target()).split('-').last);
    if (pid != null && !_isPidAlive(pid)) return null;
    return pid == null ? 'another browser' : 'a browser (pid $pid)';
  } catch (_) {
    // broken or missing symlink
    return 'another browser';
  }
}

/// Refusal to start on [profile] while [holder] has it: Chrome would hand off to it and exit.
ChromeException _held(String profile, String holder) => ChromeException(
  'Cannot start Chrome on $profile: $holder is already using that profile; '
  'quit it, wait for the other run to finish, or give this one a store of its own',
);

bool _isPidAlive(int pid) => OsBridge.isPidAlive(pid);

/// The endpoint from `DevToolsActivePort`, where Chrome writes the port it took and its path.
Future<Uri> _activePort(Directory profile, Process process, Duration timeout) async {
  final file = File('${profile.path}/DevToolsActivePort');
  final deadline = DateTime.now().add(timeout);
  var exited = false;
  unawaited(process.exitCode.then((_) => exited = true));
  final token = Cancel.token;
  while (DateTime.now().isBefore(deadline)) {
    // A cancel while it starts: the caller stops the process and erases its folder.
    token?.check();
    if (await file.exists()) {
      final lines = (await file.readAsString()).split('\n');
      if (lines.length >= 2 && lines[0].trim().isNotEmpty) {
        return Uri.parse('ws://127.0.0.1:${lines[0].trim()}${lines[1].trim()}');
      }
    }
    if (exited) break;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  if (exited) throw const ChromeException('Chrome exited before it was ready');
  throw TimeoutBridge('Chrome start', timeout);
}

Future<void> _erase(Directory directory) async {
  var wait = 1;
  for (var i = 0; i < 10; i++) {
    try {
      if (await directory.exists()) await directory.delete(recursive: true);
      return;
    } on FileSystemException catch (e) {
      final code = e.osError?.errorCode;
      if (Platform.isWindows && (code == 5 || code == 32) && i < 9) {
        await Future<void>.delayed(Duration(milliseconds: wait));
        wait = (wait * 2).clamp(1, 1000);
        continue;
      }
      return; // a profile Chrome still holds stays on disk
    }
  }
}

/// The command line [Chrome.launch] and [Chrome.connect] start Chrome with: [args] last, before
/// the blank first tab, a `--disable-features=` among them merged with the ones this turns off
/// (Chrome reads only the last one).
List<String> _flags({
  required bool headless,
  required int port,
  required String profile,
  required bool stealth,
  required List<Uri> proxies,
  required List<String> args,
}) {
  final disabled = {..._quiet};
  final rest = <String>[];
  for (final arg in args) {
    if (arg.startsWith('--disable-features=')) {
      disabled.addAll(arg.substring('--disable-features='.length).split(',').where((f) => f.isNotEmpty));
    } else {
      rest.add(arg);
    }
  }
  return [
    if (headless) '--headless=new',
    '--remote-debugging-port=$port',
    '--user-data-dir=$profile',
    '--no-first-run',
    '--no-default-browser-check',
    if (stealth) '--disable-blink-features=AutomationControlled',
    if (proxies case [final proxy]) '--proxy-server=${_server(proxy)}',
    if (proxies.length > 1) '--proxy-pac-url=${_rotation(proxies)}',
    '--disable-background-networking',
    '--disable-backgrounding-occluded-windows',
    '--disable-renderer-backgrounding',
    '--disable-component-update',
    '--disable-features=${disabled.join(',')}',
    '--hide-scrollbars',
    '--mute-audio',
    ...rest,
    'about:blank',
  ];
}

/// `--proxy-server`'s value, without credentials: those are answered over the protocol.
String _server(Uri proxy) => '${proxy.scheme}://${_hostPort(proxy)}';

String _hostPort(Uri proxy) => '${proxy.host.contains(':') ? '[${proxy.host}]' : proxy.host}:${proxy.port}';

/// A PAC script, as a `data:` URL, that hands each request the next of [proxies] first and the
/// rest after it, so Chrome moves on when one cannot connect.
String _rotation(List<Uri> proxies) {
  final routes = [for (final p in proxies) '"${HttpBridge.isSocks(p) ? 'SOCKS5' : 'PROXY'} ${_hostPort(p)}"'];
  final script =
      'var routes = [${routes.join(', ')}]; var turn = 0;\n'
      'function FindProxyForURL(url, host) {\n'
      '  var i = turn++ % routes.length;\n'
      '  return routes.slice(i).concat(routes.slice(0, i)).join("; ");\n'
      '}\n';
  return 'data:application/x-ns-proxy-autoconfig;base64,${base64.encode(utf8.encode(script))}';
}

/// `net::ERR_NAME_NOT_RESOLVED` → `err name not resolved`.
String _readable(String error) =>
    error.startsWith('net::') ? error.substring(5).toLowerCase().replaceAll('_', ' ') : error;
