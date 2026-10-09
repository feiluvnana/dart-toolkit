part of '../path.dart';

final _tempName = RegExp(r'^\..+\.[0-9a-f]{16}\.tmp$');

/// Whether [name] is one of the temporary files an atomic write or a copy makes.
bool _isTemp(String name) => _tempName.hasMatch(name);

/// How many [PathExtensions.changes] debounces a batch waits at most for a pause.
const _longestBatch = 10;

/// [PathExtensions.changes].
Stream<FileChanges> _changes(String path, Duration debounce) {
  if (debounce <= Duration.zero) throw ArgumentError.value(debounce, 'debounce', 'Invalid debounce: not positive');
  final token = Cancel.token;
  StreamSubscription<FileSystemEvent>? events;
  // [quiet] waits for a pause; [longest] ends a batch that changes never pause in.
  Timer? quiet, longest;
  void Function()? unlisten;
  var added = <Path>{}, modified = <Path>{}, removed = <Path>{};
  var stopped = false;
  late final StreamController<FileChanges> out;

  Future<void> stop() async {
    stopped = true;
    quiet?.cancel();
    longest?.cancel();
    unlisten?.call();
    await events?.cancel();
  }

  out = StreamController<FileChanges>(
    onListen: () async {
      if (token != null) {
        unlisten = token.onCancel(() {
          stop();
          if (!out.isClosed) {
            out
              ..addError(CancelledException.of(token))
              ..close();
          }
        });
        if (token.isCancelled) return;
      }
      final isDir = await FileSystemEntity.isDirectory(path);
      // A file is watched through its folder: an atomic write renames a new file over it,
      // which ends a watch on the file itself.
      final folder = isDir ? path : _dirname(path);
      if (!isDir && !await FileSystemEntity.isDirectory(folder)) {
        // A watch on a missing folder never fires and never ends: say so instead.
        unlisten?.call();
        out
          ..addError(FileBridge.notFound(folder, 'Cannot watch'))
          ..close();
        return;
      }
      // Cancelled while it looked: nothing is started, so nothing is left running.
      if (stopped) return;
      final name = _basename(path);
      bool wanted(String f) => isDir ? !_isTemp(_basename(f)) : _basename(f) == name;
      events = (isDir ? Directory(path).watch(recursive: true) : Directory(folder).watch()).listen(
        (e) {
          final hit = [e.path, if (e is FileSystemMoveEvent && e.destination != null) e.destination!].where(wanted);
          if (hit.isEmpty) return;
          switch (e) {
            case FileSystemCreateEvent():
              added.addAll(hit.map(Path.new));
            case FileSystemDeleteEvent():
              removed.addAll(hit.map(Path.new));
            case FileSystemMoveEvent(:final destination?):
              // Linux reports an atomic write as its temp moved over the file: a modification.
              if (wanted(e.path)) removed.add(Path(e.path));
              if (wanted(destination)) {
                (_isTemp(_basename(e.path)) ? modified : added).add(Path(destination));
              }
            case _:
              modified.addAll(hit.map(Path.new));
          }
          void flush() {
            quiet?.cancel();
            longest?.cancel();
            longest = null;
            final ready = FileChanges(added: added, modified: modified, removed: removed);
            added = {};
            modified = {};
            removed = {};
            out.add(ready);
          }

          quiet?.cancel();
          quiet = Timer(debounce, flush);
          longest ??= Timer(debounce * _longestBatch, flush);
        },
        onError: out.addError,
        onDone: () {
          quiet?.cancel();
          longest?.cancel();
          if (added.isNotEmpty || modified.isNotEmpty || removed.isNotEmpty) {
            out.add(FileChanges(added: added, modified: modified, removed: removed));
          }
          unlisten?.call();
          out.close();
        },
      );
    },
    onCancel: stop,
  );
  return out.stream;
}

/// How many of a followed file's first bytes tell it from its replacement.
const _headBytes = 64;

/// How much a tail reads at a time.
const _tailChunk = 1 << 20;

/// [PathExtensions.tail].
Stream<String> _tail(String path, Encoding encoding) {
  final token = Cancel.token;
  late final StreamController<String> out;
  Timer? poll;
  StreamSubscription<FileSystemEvent>? watch;
  void Function()? unlisten;
  var position = 0;
  // The file's first bytes and its identity, to tell a file replaced by a bigger one from the
  // same one grown: a rotation can keep both the size and the first bytes.
  var head = Uint8List(0);
  (int, int)? id;
  Sink<List<int>> lines() =>
      encoding.decoder.startChunkedConversion(const LineSplitter().startChunkedConversion(_Lines(out.add)));
  late var decoded = lines();
  var busy = false, again = false, stopped = false;

  void restart() {
    position = 0;
    head = Uint8List(0);
    id = null;
    decoded = lines();
  }

  Future<void> check() async {
    if (busy) {
      again = true;
      return;
    }
    busy = true;
    try {
      do {
        again = false;
        final size = (await FileStat.stat(path)).size;
        if (size < 0) {
          if (position > 0 || head.isNotEmpty) restart();
          continue;
        }
        if (size < position) restart();
        final now = _fileId(path);
        if (id != null && now != null && now != id) restart();
        id ??= now;
        // Unchanged, and the head as long as it can be: nothing to open.
        if (size == position && head.length >= (size < _headBytes ? size : _headBytes)) continue;
        final raf = await File(path).open();
        try {
          if (head.isNotEmpty && !_startsWith(await raf.read(head.length), head)) restart();
          await raf.setPosition(position);
          while (!stopped) {
            final chunk = await raf.read(_tailChunk);
            if (chunk.isEmpty) break;
            position += chunk.length;
            decoded.add(chunk);
          }
          if (head.length < _headBytes) {
            await raf.setPosition(0);
            head = await raf.read(_headBytes);
          }
        } finally {
          await raf.close();
        }
      } while (again && !stopped);
    } on FileSystemException catch (_) {
      // Gone between the stat and the open, or unreadable for now: the next check retries.
    } finally {
      busy = false;
    }
  }

  void stop() {
    stopped = true;
    poll?.cancel();
    watch?.cancel();
    unlisten?.call();
  }

  out = StreamController<String>(
    onListen: () async {
      if (token != null) {
        unlisten = token.onCancel(() {
          stop();
          if (!out.isClosed) {
            out
              ..addError(CancelledException.of(token))
              ..close();
          }
        });
        if (token.isCancelled) return;
      }
      final stat = await FileStat.stat(path);
      if (stat.type != FileSystemEntityType.notFound) {
        position = stat.size;
        id = _fileId(path);
        try {
          final raf = await File(path).open();
          try {
            head = await raf.read(_headBytes);
          } finally {
            await raf.close();
          }
        } on FileSystemException catch (_) {} // gone or unreadable already: the poll picks it up
      }
      // Cancelled while it looked: nothing is started, so nothing is left running.
      if (stopped) return;
      final name = _basename(path);
      try {
        final folder = Directory(_dirname(_absolute(path)));
        if (FileSystemEntity.isWatchSupported && await folder.exists() && !stopped) {
          watch = folder.watch().listen((e) {
            if (_basename(e.path) == name) check();
          }, onError: (Object _) {}); // the poll below still checks
        }
      } on FileSystemException catch (_) {} // no watch here: the poll alone checks
      if (stopped) return watch?.cancel();
      poll = Timer.periodic(const Duration(milliseconds: 100), (_) => check());
    },
    onCancel: stop,
  );
  return out.stream;
}

bool _startsWith(List<int> bytes, List<int> head) {
  if (bytes.length < head.length) return false;
  for (var i = 0; i < head.length; i++) {
    if (bytes[i] != head[i]) return false;
  }
  return true;
}

/// A sink that hands each line to a callback.
final class _Lines implements Sink<String> {
  final void Function(String line) _add;

  _Lines(this._add);

  @override
  void add(String line) => _add(line);

  @override
  void close() {}
}

final _tkClaim = NativeBridge.main
    .require()
    .lookupFunction<Int32 Function(Pointer<Uint8>, IntPtr), int Function(Pointer<Uint8>, int)>('tk_claim');
final _tkUnclaim = NativeBridge.main
    .require()
    .lookupFunction<Int32 Function(Pointer<Uint8>, IntPtr), int Function(Pointer<Uint8>, int)>('tk_unclaim');

/// The locks [PathExtensions.lock] holds or waits for in this isolate, by the path asked for,
/// each the turn of the last caller, so callers here are served in order.
final _turns = <String, Future<void>>{};

/// The locks this isolate holds, by the file's real path. The operating system's lock is the
/// process's, so two holders in it would both get it: the native library's claims make a lock
/// exclusive across this process's isolates too.
final _locks = <String>{};

/// Claims [key] for this process: in this isolate's set, and in the native library's for every
/// isolate. `false` when someone here holds it already.
bool _claim(String key) {
  if (_locks.contains(key)) return false;
  if (NativeBridge.main.isLoaded && NativeBridge.main.withText('lock:$key', _tkClaim) != 1) return false;
  _locks.add(key);
  return true;
}

void _unclaim(String key) {
  _locks.remove(key);
  if (NativeBridge.main.isLoaded) NativeBridge.main.withText('lock:$key', _tkUnclaim);
}

/// Whether a lock failed only because another holds it: EAGAIN, EACCES, or Windows' own.
bool _contended(FileSystemException e) => const {11, 13, 35, 33}.contains(e.osError?.errorCode);

/// [PathExtensions.lock].
Future<T> _lock<T>(String path, FutureOr<T> Function() body, bool wait) async {
  // Taken before any await, so callers in this isolate are served in the order they came.
  final asked = _absolute(path);
  final before = _turns[asked];
  if (before != null && !wait) throw _held(path, 'this process');
  final turn = Completer<void>();
  _turns[asked] = turn.future;
  try {
    if (before != null) await (Cancel.token == null ? before : before.cancellable);
    return await _locked(path, body, wait);
  } finally {
    turn.complete();
    if (identical(_turns[asked], turn.future)) _turns.remove(asked);
  }
}

/// [body] under the lock on [path], once this isolate's turn has come.
Future<T> _locked<T>(String path, FutureOr<T> Function() body, bool wait) async {
  final file = File(path);
  // Never opened while another part of this process may hold it: on POSIX, closing any handle
  // to a file drops every lock the process has on it.
  if (!await file.exists()) await file.create(recursive: true);
  // By the real path, so a link to the file and the file are one lock.
  final key = await file.resolveSymbolicLinks();
  for (var pause = 1; !_claim(key); pause = pause < 50 ? pause * 2 : 50) {
    if (!wait) throw _held(path, 'this process');
    await Duration(milliseconds: pause).delay();
  }
  try {
    final raf = await file.open(mode: FileMode.append);
    try {
      for (var pause = 1; ; pause = pause < 50 ? pause * 2 : 50) {
        try {
          await raf.lock(FileLock.exclusive);
          break;
        } on FileSystemException catch (e) {
          if (!_contended(e)) rethrow;
        }
        if (!wait) throw _held(path, 'another process');
        await Duration(milliseconds: pause).delay();
      }
      return await body();
    } finally {
      await raf.close();
    }
  } finally {
    _unclaim(key);
  }
}

/// A lock someone else holds: a runtime fact, so an exception naming the lock.
FileSystemException _held(String path, String by) => FileSystemException('Cannot lock: held by $by', path);
