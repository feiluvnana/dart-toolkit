part of '../../chrome.dart';

/// Scheme, host and port: what a browser means by *the same site* for a credential.
String _origin(Uri? url) => url == null ? '' : '${url.scheme}://${url.host.toLowerCase()}:${url.port}';

/// [name] in [dir], or `name (2).ext`, `name (3).ext`… — the first that is not taken, so a
/// download never lands on a file that is already there.
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

/// What a site's suggested name becomes on disk: the last segment of it, and never `..`.
///
/// Chrome sanitises the name it suggests; this is the second lock on the door, because the
/// name is the one part of the destination a remote host chooses.
String _fileName(String suggested) {
  final slash = suggested.lastIndexOf('/');
  final backslash = suggested.lastIndexOf(r'\');
  final lastSlash = slash > backslash ? slash : backslash;
  final raw = lastSlash == -1 ? suggested : suggested.substring(lastSlash + 1);
  final name = raw.trim();
  return name.isEmpty || name == '.' || name == '..' ? 'download' : name;
}

/// What a fresh profile would otherwise fetch on its own, in its first minute: ~40 MB of
/// optimization-guide models and hints, and translate's and the media router's services.
const _quiet = [
  'Translate',
  'MediaRouter',
  'OptimizationGuideModelDownloading',
  'OptimizationHintsFetching',
  'OptimizationTargetPrediction',
  'OptimizationHints',
];

/// The `sh` a launched Chrome runs under on macOS and Linux, so that it cannot outlive this
/// program: `sh -c _reaper <name> <scratch> <chrome> <args…>`.
///
/// Its stdin is a pipe only this process holds the other end of, so end-of-file on it arrives
/// the moment this process is gone however it went — `kill -9` included, which no exit hook
/// sees. Then: `SIGTERM` to the browser alone, which shuts down in order and writes its
/// cookies (its network process, signalled at the same moment, would die with them
/// unwritten), and `SIGKILL` to its process group five seconds later. However Chrome ends —
/// that, [ChromeClient.close] closing the pipe, a crash — the shell erases `<scratch>` and
/// exits with Chrome's status, which is how [_activePort] sees a browser that died starting.
/// It traps ^C and friends rather than dying of them: they reach this shell too, and a shell
/// killed by one would leave its cleanup undone.
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
kill -KILL -- -$watcher || kill -KILL $watcher
rm -rf "$scratch"
exit $status
""";

/// Whether a launched Chrome runs under [_reaper]: everywhere there is a POSIX `sh`.
final _reaps = !Platform.isWindows;

/// Stops a launched browser: through its [_reaper] by closing the pipe it waits on — which
/// gives Chrome five seconds before it kills it, so this gives the reaper ten — else by
/// signal; `SIGKILL` either way when it will not go.
Future<void> _stop(Process process) async {
  _reaps ? await process.stdin.close().catchError((Object _) {}) : process.kill();
  await process.exitCode.timeout(
    Duration(seconds: _reaps ? 10 : 5),
    onTimeout: () => process.kill(ProcessSignal.sigkill) ? -9 : 0,
  );
}

/// Whether the DevTools cookie [c] goes to [url], by RFC 6265's rules: `Secure` only over https,
/// a leading dot on the domain for its subdomains too, and a path on a `/` boundary.
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

/// The headers that are a credential, and so go to one origin only; `http`'s own rule.
const _credential = {'authorization', 'cookie', 'proxy-authorization'};

/// Headers Chrome sets for itself; sending them from a request corrupts the render.
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

/// The browser's websocket endpoint on [host]:[port], or `null` when nothing answers there.
Future<Uri?> _devtools(String host, int port) async {
  final probe = IoClient();
  try {
    final res = await probe.send(Request('GET', Uri.parse('http://$host:$port/json/version'))).then((r) => r.read());
    if (!res.isOk) return null;
    return Uri.tryParse(res.json['webSocketDebuggerUrl'].to<String>());
  } catch (_) {
    // Nothing listening, or something that is not DevTools. Either way there is no browser.
    return null;
  } finally {
    probe.close();
  }
}

/// [executable], else `CHROME_PATH`, else the first of [_chromes] that is installed.
String _binary(String? executable) {
  if (executable ?? Platform.environment['CHROME_PATH'] case final path? when path.isNotEmpty) return path;
  for (final candidate in _chromes) {
    if (File(candidate).existsSync()) return candidate;
  }
  throw const ClientException('No Chrome found. Install Chrome or Chromium, set CHROME_PATH, or pass executable:.');
}

/// Who holds [profile], as Chrome's own lock records it, or `null` when nothing does.
///
/// The lock is a symlink named `SingletonLock` pointing at `<host>-<pid>`. It is read rather
/// than removed: a lock with a live browser behind it is not this program's to break.
Future<String?> _heldBy(Directory profile) async {
  final lock = Link('${profile.path}/SingletonLock');
  try {
    if (!await lock.exists()) return null;
    final target = await lock.target();
    final pid = int.tryParse(target.split('-').last);
    if (pid != null && !_isPidAlive(pid)) return null;
    return pid == null ? 'another browser' : 'a browser (pid $pid)';
  } catch (_) {
    return 'another browser';
  }
}

bool _isPidAlive(int pid) {
  try {
    return Platform.isWindows ? true : Process.runSync('kill', ['-0', '$pid']).exitCode == 0;
  } catch (_) {
    return false;
  }
}

/// Chrome writes the port it actually took, and the browser's websocket path, into the
/// profile directory as it starts.
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

/// What `--proxy-server` wants: scheme, host and port, and never the credentials — those
/// cannot travel on a command line and are answered over the protocol instead.
String _server(Uri proxy) => '${proxy.scheme}://${proxy.host}:${proxy.port}';

/// `net::ERR_NAME_NOT_RESOLVED` says the same thing with less shouting.
String _readable(String error) =>
    error.startsWith('net::') ? error.substring(5).toLowerCase().replaceAll('_', ' ') : error;
