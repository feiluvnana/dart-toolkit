part of '../async.dart';

// What a pool with a folder store keeps there:
//
// - `local/<pid>.json`: a program's own unfinished jobs, locked while it runs, so the next run
//   continues what a crash or a close left;
// - `jobs.json`: the detached jobs, kept by the runner, the one process that runs them;
// - `runner.json`: where the runner listens (a loopback port and the token it asks for), owner
//   only; `runner.lock`, held while it runs; `runner.log`, what it could tell no one.
//
// A program shows the runner's jobs over the socket: a line of JSON per change comes in, a line
// per `add`, `pause`, `resume` or `remove` goes out.

/// The variable that makes a program the runner of the pool whose store it names.
const _runnerKey = 'DART_TOOLKIT_POOL';

/// The version of what a pool writes in its store.
const _storeVersion = 1;

/// How long a runner with nothing connected and nothing to run waits before it ends.
const _idleLimit = Duration(seconds: 5);

/// How often one job's progress crosses the socket, at most; every other change crosses at once.
const _reportGap = Duration(milliseconds: 100);

/// How long a program waits for a runner it started to answer.
const _startLimit = Duration(seconds: 30);

String _join(String folder, String name) => '$folder${Platform.pathSeparator}$name';

/// [text], a file of the store at [path], as the list of jobs it holds. A file that does not
/// read, or that another version wrote, is a [FormatException] naming it.
List<Map<String, Object?>> _readJobs(String text, String path) {
  if (text.trim().isEmpty) return const [];
  try {
    final json = jsonDecode(text) as Map;
    if (json['version'] != _storeVersion) {
      throw FormatException('version ${json['version']}, expected $_storeVersion');
    }
    return [for (final job in json['jobs'] as List) (job as Map).cast<String, Object?>()];
  } on FormatException catch (e) {
    throw FormatException('Invalid pool store in $path: ${e.message}');
  } catch (e) {
    throw FormatException('Invalid pool store in $path: $e');
  }
}

String _jobsText(List<Map<String, Object?>> jobs) => jsonEncode({'version': _storeVersion, 'jobs': jobs});

// ---- a program's own jobs ------------------------------------------------------------------

/// This program's unfinished jobs ([_kept] names them), in `local/<pid>.json`, locked while it
/// runs.
final class _Record<I, T> {
  final String _folder;
  final _Codec<I, T> _codec;
  final List<Job<I, T>> Function() _kept;
  RandomAccessFile? _held;
  Future<void> _writing = Future.value();
  bool _due = false;

  _Record(this._folder, this._codec, this._kept);

  String get _local => _join(_folder, 'local');

  File get _file => File(_join(_local, '$pid.json'));

  /// The jobs of the runs that ended without finishing them, as (id, item, paused): each such
  /// record is read and emptied under its lock, then deleted. A run still going holds its lock,
  /// and is left alone.
  Future<List<(String, I, bool)>> adopt() async {
    final out = <(String, I, bool)>[];
    final dir = Directory(_local);
    if (!await dir.exists()) return out;
    await for (final entry in dir.list()) {
      if (entry is! File || !entry.path.endsWith('.json') || entry.path == _file.path) continue;
      RandomAccessFile? held;
      try {
        held = await entry.open(mode: FileMode.append);
        await held.lock(FileLock.exclusive);
      } on FileSystemException catch (_) {
        await held?.close();
        continue; // its program is running, or another program took it first
      }
      try {
        await held.setPosition(0);
        final text = utf8.decode(await held.read(await held.length()), allowMalformed: true);
        // Emptied before the lock goes: a program that opened it meanwhile finds nothing to take.
        await held.truncate(0);
        for (final job in _readJobs(text, entry.path)) {
          out.add(('${job['id']}', _codec.itemOf(job['item']), job['paused'] == true));
        }
      } finally {
        await held.close();
        try {
          await entry.delete();
        } on FileSystemException catch (_) {} // another program took it first
      }
    }
    return out;
  }

  /// Writes the jobs as this program's, in place (the lock holds the file, so it is not
  /// replaced). Changes made while a write waits share it.
  Future<void> save() {
    if (_due) return _writing;
    _due = true;
    return _writing = _writing.catchError((Object _) {}).then((_) async {
      // A failed write before is replaced by this whole one.
      _due = false;
      final bytes = utf8.encode(
        _jobsText([
          for (final job in _kept())
            {'id': job.id, 'item': _codec.json(job.item), if (job.status is Paused) 'paused': true},
        ]),
      );
      final held = _held ??= await _open();
      await held.setPosition(0);
      await held.writeFrom(bytes);
      await held.truncate(bytes.length);
      await held.flush();
    });
  }

  Future<RandomAccessFile> _open() async {
    await Directory(_local).create(recursive: true);
    final held = await _file.open(mode: FileMode.append);
    await held.lock(FileLock.exclusive);
    return held;
  }

  /// The last write, then the lock let go: the next run continues the jobs. With none left,
  /// the record goes.
  Future<void> close() async {
    final left = _kept().isNotEmpty;
    if (left || _held != null) {
      await save().catchError((Object _) {}); // unwritten, it leaves nothing to continue
    }
    await _writing.catchError((Object _) {}); // as above
    await _held?.close();
    _held = null;
    if (!left) {
      try {
        await _file.delete();
      } on FileSystemException catch (_) {} // never written: nothing to delete
    }
  }
}

// ---- the program's side of the runner ------------------------------------------------------

/// A pool's connection to the runner of its detached jobs.
final class _Link<I, T> {
  final Pool<I, T> _pool;
  final String _folder;

  /// What was sent while no runner was connected, sent once one is.
  final _outbox = <String>[];

  /// Jobs added here that the runner has not listed back yet: a first list without them is
  /// older than they are.
  final _adding = <String>{};
  Socket? _socket;
  bool _closed = false;
  Future<void> _opened = Future.value();

  /// Connects at once, starting the runner when none answers.
  _Link(this._pool, this._folder) {
    _opened = _connect();
  }

  _Link._idle(this._pool, this._folder);

  /// The link to the runner when one runs, or when the store has detached jobs to continue (it
  /// is started then); `null` when neither.
  static Future<_Link<I, T>?> find<I, T>(Pool<I, T> pool, String folder) async {
    // Known before it dials: the jobs it hears of may be controlled at once.
    final link = pool._link = _Link<I, T>._idle(pool, folder);
    if (await link._dial()) return link;
    final file = File(_join(folder, 'jobs.json'));
    final saved = await file.exists()
        ? _readJobs(await file.readAsString(), file.path)
        : const <Map<String, Object?>>[];
    if (!saved.any((job) => const {'waiting', 'running'}.contains((job['status'] as Map?)?['kind']))) {
      pool._link = null;
      return null;
    }
    await (link._opened = link._connect());
    return link;
  }

  /// [_open], failing the jobs waiting on it when no runner answers.
  Future<void> _connect() => _open().catchError((Object error, StackTrace trace) {
    for (final id in [..._adding]) {
      _pool._jobs[id]?._finish(Failed(_pool._jobs[id]!.item, error, trace));
    }
  });

  Future<void> _open() async {
    final deadline = Clock.current.elapsed + _startLimit;
    var started = false;
    while (!_closed) {
      if (await _dial()) return;
      if (!started) {
        await _start();
        started = true;
      }
      if (Clock.current.elapsed > deadline) {
        throw TimeoutBridge('the runner of $_folder (its log is ${_join(_folder, 'runner.log')})', _startLimit);
      }
      await 100.ms.delay();
    }
  }

  /// Whether the runner answered: its socket, past the token and its first list of jobs.
  Future<bool> _dial() async {
    final Map<Object?, Object?> found;
    try {
      found = jsonDecode(await File(_join(_folder, 'runner.json')).readAsString()) as Map;
    } catch (_) {
      return false; // no runner yet, or one writing its file
    }
    Socket? socket;
    try {
      socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        (found['port'] as num).toInt(),
        timeout: const Duration(seconds: 2),
      );
      socket.write('${jsonEncode({'token': found['token']})}\n');
      final first = Completer<void>();
      final connected = socket;
      connected.done.catchError((Object _) => _lost(connected)); // a runner gone mid-write, as onDone
      final reading = connected
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            (line) {
              _hear(line);
              if (!first.isCompleted) first.complete();
            },
            onError: (Object _) => _lost(connected), // the end says the rest
            onDone: () => _lost(connected),
            cancelOnError: true,
          );
      try {
        await first.future.timeout(const Duration(seconds: 5));
      } catch (_) {
        await reading.cancel();
        rethrow;
      }
      _socket = connected;
      _outbox.forEach(connected.write);
      _outbox.clear();
      return true;
    } catch (_) {
      socket?.destroy(); // a stale port, or a process that is not the runner
      return false;
    }
  }

  /// Starts this program again, detached, as the runner of the store.
  Future<void> _start() async {
    final exe = Platform.resolvedExecutable;
    final script = Platform.script.toFilePath();
    // Compiled, the script is the executable; under the VM it is a source the VM runs.
    final source = script != exe;
    final config = source ? await Isolate.packageConfig : null;
    await Directory(_folder).create(recursive: true);
    await Process.start(
      exe,
      [
        if (source) ...[if (config != null) '--packages=${config.toFilePath()}', script],
      ],
      environment: {...Env.all, _runnerKey: _folder},
      includeParentEnvironment: false,
      mode: ProcessStartMode.detached,
    );
  }

  void _lost(Socket socket) {
    if (!identical(_socket, socket)) return;
    _socket = null;
    // The runner went away (a crash, or its end between two looks): find or start one. A
    // failure leaves what is sent next in the outbox, for the one after.
    if (!_closed) _opened = _connect();
  }

  void _hear(String line) {
    final message = jsonDecode(line) as Map;
    switch (message) {
      case {'jobs': final List<Object?> all}:
        final seen = <String>{for (final json in all) _upsert(json! as Map<Object?, Object?>).id};
        for (final job in [..._pool._jobs.values]) {
          if (job._remote && !seen.contains(job.id) && !_adding.contains(job.id)) _gone(job.id);
        }
      case {'job': final Map<Object?, Object?> json}:
        _upsert(json);
      case {'warned': final String id, 'warning': final Object? warning}:
        if (_pool._jobs[id] case final job?) job._set(Warned(job.item, _warningOf(warning)));
      case {'removed': final String id}:
        _gone(id);
    }
  }

  Job<I, T> _upsert(Map<Object?, Object?> json) {
    final id = '${json['id']}';
    _adding.remove(id);
    var job = _pool._jobs[id];
    if (job == null) {
      job = Job<I, T>._(_pool, id, _pool._codec.itemOf(json['item']), isDetached: true);
      _pool._meet(job);
    }
    final status = _pool._codec.statusOf(job.item, json['status']);
    if (status.isFinal) {
      if (!(job.status.isFinal && job.status.runtimeType == status.runtimeType)) job._finish(status);
    } else {
      job._set(status);
    }
    return job;
  }

  void _gone(String id) {
    _adding.remove(id);
    if (_pool._jobs[id] case final job?) {
      _pool._forget(job);
      job._removed = true;
      if (!job.status.isFinal) {
        job._finish(Stopped(job.item, Stopped.removed));
      } else {
        _pool._changed(job);
      }
    }
  }

  void add(Job<I, T> job) {
    _adding.add(job.id);
    send({
      'add': {'id': job.id, 'item': _pool._codec.item(job.item)},
    });
  }

  void send(Map<String, Object?> message) {
    final line = '${jsonEncode(message)}\n';
    if (_socket case final socket?) {
      socket.write(line);
    } else {
      _outbox.add(line);
    }
  }

  /// Sends what waits (after a runner answers, if one is on its way) and disconnects.
  Future<void> close() async {
    if (_outbox.isNotEmpty) await _opened.timeout(_startLimit, onTimeout: () {});
    _closed = true;
    final socket = _socket;
    _socket = null;
    if (socket == null) return;
    // Our half closes after what was sent; the runner's, read no more, would otherwise keep this
    // program alive until the runner ends.
    try {
      await socket.close().timeout(const Duration(seconds: 2));
    } catch (_) {
      // A runner gone already, or one not reading: nothing more to say to it.
    }
    socket.destroy();
  }
}

// ---- the runner ----------------------------------------------------------------------------

/// The process that runs a pool's detached jobs and serves them to every program that connects.
final class _Runner<I, T> {
  final Pool<I, T> _pool;
  final String _folder;
  final _clients = <Socket>{};
  final _sent = <String, Duration>{};
  final _later = <String, Timer>{};
  Future<void> _writing = Future.value();
  bool _dirty = false;
  bool _ready = false;

  _Runner(this._pool, this._folder);

  /// Appends [message] to the store's log: a detached runner has no stderr.
  static void note(String folder, Object message) {
    try {
      Directory(folder).createSync(recursive: true);
      File(
        _join(folder, 'runner.log'),
      ).writeAsStringSync('${DateTime.now().toIso8601String()} $message\n', mode: FileMode.append);
    } on FileSystemException catch (_) {} // a log that cannot be written is no reason to stop the jobs
  }

  Future<Never> serve() async {
    await Directory(_folder).create(recursive: true);
    // What nothing caught goes to the log.
    return runZonedGuarded(_serve, (error, trace) => note(_folder, '$error\n$trace'))!;
  }

  Future<Never> _serve() async {
    final lock = await File(_join(_folder, 'runner.lock')).open(mode: FileMode.append);
    try {
      await lock.lock(FileLock.exclusive);
    } on FileSystemException catch (_) {
      exit(0); // another runner has the store
    }
    final port = File(_join(_folder, 'runner.json'));
    try {
      await _load();
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final token = '${FileBridge.token()}${FileBridge.token()}';
      await FileBridge.write(port.path, const []);
      if (!Platform.isWindows) await Process.run('chmod', ['600', port.path]); // the token is the key
      await FileBridge.write(port.path, utf8.encode(jsonEncode({'port': server.port, 'token': token, 'pid': pid})));
      note(_folder, 'running on port ${server.port}');
      server.listen((socket) => _welcome(socket, token));

      var idle = Clock.current.elapsed;
      final ended = Completer<void>();
      Timer.periodic(const Duration(seconds: 1), (timer) {
        final busy = _pool._jobs.values.any((job) => job.status is Waiting || job.status is Running);
        if (_clients.isNotEmpty || busy) {
          idle = Clock.current.elapsed;
        } else if (Clock.current.elapsed - idle >= _idleLimit) {
          timer.cancel();
          ended.complete();
        }
      });
      await ended.future;
      note(_folder, 'idle: ending');
      await server.close();
      await _pool.close();
      await _writing;
    } catch (error, trace) {
      note(_folder, '$error\n$trace');
    }
    try {
      await port.delete();
    } on FileSystemException catch (_) {} // already gone is the goal
    exit(0);
  }

  /// The jobs the store keeps: an unfinished one runs again, a paused one waits, a finished one
  /// is shown as it ended.
  Future<void> _load() async {
    final file = File(_join(_folder, 'jobs.json'));
    final saved = await file.exists()
        ? _readJobs(await file.readAsString(), file.path)
        : const <Map<String, Object?>>[];
    for (final saved in saved) {
      final item = _pool._codec.itemOf(saved['item']);
      final status = _pool._codec.statusOf(item, saved['status']);
      final job = Job<I, T>._(_pool, '${saved['id']}', item, isDetached: true);
      _pool._meet(job);
      switch (status) {
        case Paused():
          job._set(Paused(item));
        case Done() || Failed() || Stopped() || Skipped():
          job._finish(status);
        case _:
          _pool._start(job);
      }
    }
    _ready = true;
    persist();
  }

  /// Writes every job to `jobs.json`: atomically, one write at a time, changes during a write
  /// sharing the next.
  void persist() {
    if (!_ready || _dirty) return;
    _dirty = true;
    _writing = _writing.then((_) async {
      _dirty = false;
      try {
        await _writeJobs();
      } catch (e, st) {
        note(_folder, 'cannot write the jobs: $e\n$st');
      }
    });
  }

  Future<void> _writeJobs() async {
    final codec = _pool._codec;
    final jobs = [
      for (final job in _pool._jobs.values)
        {
          'id': job.id,
          'item': codec.json(job.item),
          'status': switch (job.status) {
            Waiting() || Running() => const {'kind': 'waiting'}, // run again by the next runner
            final other => codec.status(other),
          },
        },
    ];
    await FileBridge.write(_join(_folder, 'jobs.json'), utf8.encode(_jobsText(jobs)));
  }

  void _welcome(Socket socket, String token) {
    // A program that leaves mid-write resets the socket: that is its leaving, said by onDone.
    socket.done.catchError((Object _) => _clients.remove(socket));
    var trusted = false;
    socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            final Map<Object?, Object?> message;
            try {
              message = jsonDecode(line) as Map;
            } on FormatException catch (_) {
              return socket.destroy(); // not one of ours
            }
            if (!trusted) {
              if (message['token'] != token) return socket.destroy();
              trusted = true;
              _clients.add(socket);
              _write(socket, {
                'jobs': [for (final job in _pool._jobs.values) _json(job)],
              });
              return;
            }
            _command(message);
          },
          onError: (Object _) => _clients.remove(socket), // a program that went away, as onDone
          onDone: () => _clients.remove(socket),
          cancelOnError: true,
        );
  }

  void _command(Map<Object?, Object?> message) {
    Job<I, T>? find(Object? id) => _pool._jobs[id];
    switch (message) {
      case {'add': {'id': final String id, 'item': final Object? json}}:
        final I item;
        try {
          item = _pool._codec.itemOf(json);
        } catch (e, st) {
          // The program that sent it hears why, rather than waiting on it.
          final failed = {'kind': 'failed', 'error': _errorJson(e), 'trace': '$st'};
          return _broadcast({
            'job': {'id': id, 'item': json, 'status': failed},
          });
        }
        final job = Job<I, T>._(_pool, id, item, isDetached: true);
        _pool._meet(job);
        _pool._changed(job, rest: true);
        _pool._start(job);
      case {'pause': final id}:
        find(id)?.pause();
      case {'resume': final id}:
        find(id)?.resume();
      case {'remove': final id}:
        find(id)?.remove();
      case {'cancel': final id, 'reason': final String reason}:
        find(id)?.cancel(reason);
    }
  }

  Map<String, Object?> _json(Job<I, T> job) => {
    'id': job.id,
    'item': _pool._codec.json(job.item),
    'status': _pool._codec.status(job.status),
  };

  /// [job] moved on: every program hears of it, its progress at most every [_reportGap].
  void tell(Job<I, T> job, Warned<I, T>? note) {
    if (note != null) return _broadcast({'warned': job.id, 'warning': _warningJson(note.warning)});
    final last = _sent[job.id];
    final now = Clock.current.elapsed;
    if (job.status is Running && last != null && now - last < _reportGap) {
      _later[job.id] ??= Timer(_reportGap - (now - last), () {
        _later.remove(job.id);
        if (_pool._jobs.containsKey(job.id)) _send(job);
      });
      return;
    }
    _later.remove(job.id)?.cancel();
    _send(job);
  }

  void removed(Job<I, T> job) {
    _later.remove(job.id)?.cancel();
    _sent.remove(job.id);
    _broadcast({'removed': job.id});
    persist();
  }

  void _send(Job<I, T> job) {
    _sent[job.id] = Clock.current.elapsed;
    _broadcast({'job': _json(job)});
  }

  void _broadcast(Map<String, Object?> message) {
    for (final socket in [..._clients]) {
      _write(socket, message);
    }
  }

  void _write(Socket socket, Map<String, Object?> message) {
    try {
      socket.write('${jsonEncode(message)}\n');
    } on Object catch (_) {
      _clients.remove(socket); // closed under us; its onDone follows
    }
  }
}
