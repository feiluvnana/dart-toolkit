part of '../../chrome.dart';

/// Scheme, host and port: the origin a credential is bound to.
String _origin(Uri? url) => url == null ? '' : '${url.scheme}://${url.host.toLowerCase()}:${url.port}';

/// [name] in [dir], or the first free `name (n).ext`: a download never overwrites.
Future<Path> _unused(Path dir, String name) async {
  final dot = name.indexOf('.', 1);
  final (stem, ext) = dot == -1 ? (name, '') : (name.substring(0, dot), name.substring(dot));
  var candidate = dir / name;
  for (
    var n = 2;
    await FileSystemEntity.type(candidate.path, followLinks: false) != FileSystemEntityType.notFound;
    n++
  ) {
    candidate = dir / '$stem ($n)$ext';
  }
  return candidate;
}

/// The last segment of a site's suggested name, never `..`: Chrome sanitises it too, but the
/// remote host chooses it.
String _fileName(String suggested) {
  final name = suggested.split(RegExp(r'[/\\]')).last.trim();
  return name.isEmpty || name == '.' || name == '..' ? 'download' : name;
}

/// Features a fresh profile would use to fetch ~40 MB of models and services in its first minute.
const _quiet = [
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
/// five seconds later. However Chrome ends, the shell erases `<scratch>` and exits with
/// Chrome's status, which is how [_activePort] sees a browser that died starting. It traps ^C
/// because a shell killed by one would leave its cleanup undone.
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
rm -rf "$scratch"
exit $status
""";

/// Whether a launched Chrome runs under [_reaper]: wherever there is a POSIX `sh`.
final _reaps = !Platform.isWindows;

/// Stops a launched browser: by closing the [_reaper]'s pipe (which gives Chrome 5 s, so this
/// gives it 10), else by signal; `SIGKILL` when it will not go.
Future<void> _stop(Process process) async {
  _reaps ? await process.stdin.close().catchError((Object _) {}) : process.kill();
  await process.exitCode.timeout(
    Duration(seconds: _reaps ? 10 : 5),
    onTimeout: () => process.kill(ProcessSignal.sigkill) ? -9 : 0,
  );
}

/// Whether the DevTools cookie [c] goes to [url], by RFC 6265.
bool _sendsTo(Map<String, Object?> c, Uri url) {
  if (c['secure'] == true && url.scheme != 'https') return false;
  final named = (c['domain'] as String? ?? '').toLowerCase();
  final domain = named.startsWith('.') ? named.substring(1) : named;
  final host = url.host.toLowerCase();
  if (host != domain && !(named.startsWith('.') && host.endsWith('.$domain'))) return false;
  final path = c['path'] as String? ?? '/';
  final target = url.path.isEmpty ? '/' : url.path;
  return target == path || (target.startsWith(path) && (path.endsWith('/') || target[path.length] == '/'));
}

/// Headers that are a credential, and so go to one origin only.
const _credential = {'authorization', 'cookie', 'proxy-authorization'};

/// Headers Chrome sets itself; sending them corrupts the render.
const _unsafe = {'host', 'connection', 'content-length', 'accept-encoding', 'user-agent', 'upgrade', 'keep-alive'};

const _chromes = [
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
];

/// The browser's websocket endpoint on [host]:[port], or `null` when no DevTools answers.
Future<Uri?> _devtools(String host, int port) async {
  final probe = IoClient();
  try {
    final res = await probe.send(Request('GET', Uri.parse('http://$host:$port/json/version'))).then((r) => r.read());
    return res.isOk ? Uri.tryParse(res.json['webSocketDebuggerUrl'].to<String>()) : null;
  } catch (_) {
    return null;
  } finally {
    probe.close();
  }
}

/// [executable], else `CHROME_PATH`, else the first of [_chromes] installed.
String _binary(String? executable) {
  if (executable ?? Platform.environment['CHROME_PATH'] case final path? when path.isNotEmpty) return path;
  for (final candidate in _chromes) {
    if (File(candidate).existsSync()) return candidate;
  }
  throw const ClientException('No Chrome found. Install Chrome or Chromium, set CHROME_PATH, or pass executable:.');
}

/// Who holds [profile] by Chrome's `SingletonLock` (a symlink to `<host>-<pid>`), or `null`.
/// Read, never removed: a live browser's lock is not ours to break.
Future<String?> _heldBy(Directory profile) async {
  final lock = Link('${profile.path}/SingletonLock');
  try {
    if (!await lock.exists()) return null;
    final pid = int.tryParse((await lock.target()).split('-').last);
    if (pid != null && !_isPidAlive(pid)) return null;
    return pid == null ? 'another browser' : 'a browser (pid $pid)';
  } catch (_) {
    return 'another browser';
  }
}

bool _isPidAlive(int pid) {
  try {
    return Platform.isWindows || Process.runSync('kill', ['-0', '$pid']).exitCode == 0;
  } catch (_) {
    return false;
  }
}

/// The endpoint from `DevToolsActivePort`, where Chrome writes the port it took and its path.
Future<Uri> _activePort(Directory profile, Process process, Duration timeout) async {
  final file = File('${profile.path}/DevToolsActivePort');
  final deadline = DateTime.now().add(timeout);
  var exited = false;
  unawaited(process.exitCode.then((_) => exited = true));
  while (DateTime.now().isBefore(deadline)) {
    if (await file.exists()) {
      final lines = (await file.readAsString()).split('\n');
      if (lines.length >= 2 && lines[0].trim().isNotEmpty) {
        return Uri.parse('ws://127.0.0.1:${lines[0].trim()}${lines[1].trim()}');
      }
    }
    if (exited) break;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  throw ClientException(
    exited ? 'Chrome exited before it was ready' : 'Chrome did not start within ${timeout.inSeconds}s',
  );
}

Future<void> _erase(Directory directory) async {
  try {
    if (await directory.exists()) await directory.delete(recursive: true);
  } catch (_) {}
}

/// `--proxy-server`'s value, without credentials: those are answered over the protocol.
String _server(Uri proxy) =>
    '${proxy.scheme}://${proxy.host.contains(':') ? '[${proxy.host}]' : proxy.host}:${proxy.port}';

/// `net::ERR_NAME_NOT_RESOLVED` → `err name not resolved`.
String _readable(String error) =>
    error.startsWith('net::') ? error.substring(5).toLowerCase().replaceAll('_', ' ') : error;
