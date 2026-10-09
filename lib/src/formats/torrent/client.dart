part of '../../../torrent.dart';

/// A BitTorrent client: one listen port, DHT node, peer pool and rate limit for every torrent
/// it runs. Trackers (HTTP and UDP), DHT, peer exchange, magnet metadata, uTP, local peer
/// discovery and, when asked, UPnP port mapping run natively (librqbit). A resource: [close]
/// stops it, and one dropped unclosed is stopped when collected.
///
/// ```dart
/// final client = await TorrentClient.start(into: 'downloads', store: app / 'torrent');
/// final job = client.add(await Torrent.read('a.torrent'), files: [0, 2], maxPeers: 50);
/// await job.show('ISO');                 // steps metadata, checking, downloading; then Done(path)
/// await client.close();
/// ```
///
/// {@category Formats}
final class TorrentClient implements Finalizable {
  _Session _session;

  /// The folder torrents download into, unless `add(into:)` names another.
  final Path into;

  final _jobs = <String, TorrentJob>{};
  Timer? _poll;

  TorrentClient._(this._session, this.into) {
    _TorrentNative.finalizer.attach(this, _session, detach: this);
  }

  /// Starts a client that downloads into the folder [into]. With a folder [store], it keeps
  /// its torrents and their progress there, and one started on the same store resumes them
  /// without checking their files again; a [Store.memory] (the default) keeps nothing.
  ///
  /// [port] is where peers connect (a free one when omitted); [upnp] maps it on the router.
  /// [trackers] are announced to for every torrent. [proxy] is a `socks5://` URL for peer
  /// connections; [blocklist] the URL of an IP range list. A port in use is a
  /// [SocketException].
  static Future<TorrentClient> start({
    required String into,
    Store? store,
    int? port,
    bool dht = true,
    bool upnp = false,
    bool lsd = true,
    bool utp = true,
    List<Uri> trackers = const [],
    Uri? proxy,
    Uri? blocklist,
  }) async {
    if (port != null && (port < 1 || port > 65535)) {
      throw ArgumentError.value(port, 'port', 'Invalid port, expected 1 to 65535');
    }
    final folder = Path(into).absolute;
    final state = store?.folder;
    if (state != null) await _claim(state);
    final options = {
      'folder': folder,
      'state': state == null ? null : File(state).absolute.path,
      'port': port,
      'dht': dht,
      'upnp': upnp,
      'lsd': lsd,
      'utp': utp,
      'trackers': [for (final t in trackers) '$t'],
      'proxy': proxy?.toString(),
      'blocklist': blocklist?.toString(),
    };
    // A session restores its saved torrents before it returns: off this isolate.
    final session = await Isolate.run(() => _open(options));
    final client = TorrentClient._(Pointer.fromAddress(session), folder);
    final ids = _TorrentNative.json('list torrents', (o, l) => _TorrentNative.list(client._session, o, l))! as List;
    for (final id in ids.cast<int>()) {
      final job = TorrentJob._restored(client, id);
      client._jobs[job.item.infoHash] = job;
    }
    client._watch();
    return client;
  }

  /// The version of what a client keeps in its store.
  static const _version = 1;

  /// [folder] marked as a torrent store of [_version]; one marked by another version is a
  /// [FormatException] naming it, never a silent reset.
  static Future<void> _claim(String folder) async {
    final mark = File('$folder${Platform.pathSeparator}torrent.json');
    if (await mark.exists()) {
      final version = (jsonDecode(await mark.readAsString()) as Map<String, Object?>)['version'];
      if (version != _version) {
        throw FormatException('Invalid torrent store in $folder: version $version, expected $_version');
      }
      return;
    }
    await Directory(folder).create(recursive: true);
    await FileBridge.write(mark.path, utf8.encode(jsonEncode({'version': _version})));
  }

  static int _open(Map<String, Object?> options) {
    final s = _TorrentNative.withJson(options, _TorrentNative.sessionNew);
    if (s == nullptr) throw _engine('start torrent client', NativeBridge.torrent.lastError());
    return s.address;
  }

  _Session get _live => _session == nullptr ? throw StateError('Cannot use a closed TorrentClient') : _session;

  /// The TCP port peers connect to.
  int get port => _TorrentNative.port(_live);

  /// Every torrent in this client, restored ones first, then in the order added.
  List<TorrentJob> get jobs => List.unmodifiable(_jobs.values);

  /// The torrents it has finished: they upload to peers that ask until removed or closed.
  List<TorrentJob> get seeding => [
    for (final job in _jobs.values)
      if (job.status is Done) job,
  ];

  /// Caps the client's rates in bytes per second; `null` is no cap. Zero or less is an
  /// [ArgumentError].
  void limit({int? download, int? upload}) {
    for (final (name, v) in [('download', download), ('upload', upload)]) {
      if (v != null && (v < 1 || v > 0xFFFFFFFF)) {
        throw ArgumentError.value(v, name, 'Invalid rate, expected 1 to 4 GiB/s');
      }
    }
    if (_TorrentNative.limits(_live, download ?? 0, upload ?? 0) < 0) {
      throw _engine('limit torrent rates', NativeBridge.torrent.lastError());
    }
  }

  /// [torrent] added and started: a [TorrentJob], a task that ends with where it landed
  /// (`<into>/<name>`). A torrent already here is its job, run again when it ended [Stopped] or
  /// [Failed]. [files] downloads only those indices
  /// of [Metainfo.files]; [maxPeers] caps its peers; [into] puts it elsewhere than [this.into].
  /// Files already there are checked and kept where they match.
  TorrentJob add(Torrent torrent, {String? into, List<int>? files, int? maxPeers}) {
    _live;
    if (maxPeers != null && maxPeers < 1) {
      throw ArgumentError.value(maxPeers, 'maxPeers', 'Invalid maxPeers, expected at least 1');
    }
    if (files != null) {
      final count = torrent is Metainfo ? torrent.files.length : null;
      for (final i in files) {
        if (i < 0 || (count != null && i >= count)) {
          throw ArgumentError.value(i, 'files', 'Invalid file index, expected 0 to ${(count ?? 1 << 31) - 1}');
        }
      }
    }
    if (_jobs[torrent.infoHash] case final job?) {
      // One stopped before the engine had it is added afresh; any other is run again.
      if (job._id != null || !job._status.isFinal) {
        if (job._status case Stopped() || Failed()) job.resume();
        return job;
      }
    }
    final options = {
      'folder': into == null ? this.into : File(into).absolute.path,
      'files': files,
      'paused': false,
      'max_peers': maxPeers,
    };
    return _jobs[torrent.infoHash] = TorrentJob._added(this, torrent, options);
  }

  /// Polls the jobs that run, twice a second, while any does.
  void _watch() {
    final running = _jobs.values.any((j) => j._id != null && j._polled);
    if (!running) {
      _poll?.cancel();
      _poll = null;
    } else {
      _poll ??= Timer.periodic(const Duration(milliseconds: 500), (_) {
        if (_session == nullptr) return;
        for (final job in [..._jobs.values]) {
          if (job._id != null && job._polled) job._read();
        }
        _watch();
      });
    }
  }

  /// Stops every torrent (each unfinished job ends [Stopped]), saving progress in the store,
  /// and frees the client; using it afterwards is a [StateError]. Closing twice does nothing.
  Future<void> close() async {
    if (_session == nullptr) return;
    _poll?.cancel();
    _poll = null;
    for (final job in _jobs.values) {
      job._waiting?.cancel();
      job._halt('client closed');
    }
    _TorrentNative.finalizer.detach(this);
    _TorrentNative.freeSession(_session);
    _session = nullptr;
  }
}

/// One torrent in a [TorrentClient]: a [Task] of the path it downloads to (`<into>/<name>`,
/// its file or its folder), which you can also [pause], [resume] and [remove], as a pool's job.
///
/// Its statuses are the ordinary ones: [Running] on step `metadata` (a magnet, until peers
/// send it), `checking` (what is on disk) and `downloading`, with bytes; [Paused]; then
/// [Done], [Failed] or [Stopped]. Tracker and peer trouble is a [Warned] note. Seeding after
/// [Done] is the client's ([TorrentClient.seeding]). A failure is never an unhandled error:
/// the client holds it. Made inside a task's body, its progress shows as that task's, and a
/// cancel there stops it.
///
/// {@category Formats}
final class TorrentJob implements Task<Path> {
  /// The client it runs in.
  final TorrentClient client;

  /// What was added: a [Metainfo], or the [Magnet] it came from.
  @override
  final Torrent item;

  final Zone _zone = Zone.current;
  void Function()? _unlink;

  late Status<Torrent, Path> _status;
  Completer<Path> _done = _outcome();
  Completer<Status<Torrent, Path>> _end = Completer();
  final _listeners = <StreamController<Status<Torrent, Path>>>[];
  final _warnings = <Warned<Torrent, Path>>[];
  final _meta = Completer<Metainfo>();

  /// Its id in the engine, once added; the token of the add while it runs.
  int? _id;

  /// Stops the engine's wait for completion: when it ends, or its client closes.
  CancelToken? _waiting;
  CancelToken? _adding;
  Path? _root;
  bool _wantPause = false;

  /// Since when it has had no peer while downloading, and whether that was said.
  Duration? _alone;
  bool _toldAlone = false;

  TorrentJob._added(this.client, this.item, Map<String, Object?> options) {
    _meta.future.ignore();
    _status = Running(item, label: label, step: item is Magnet ? 'metadata' : 'checking', unit: Unit.bytes);
    if (item case final Metainfo m) _meta.complete(m);
    _follow();
    _add(options);
  }

  TorrentJob._restored(this.client, int id) : item = _restoredItem(client, id) {
    _meta.future.ignore();
    _status = Running(item, label: label, step: 'checking', unit: Unit.bytes);
    if (item case final Metainfo m) _meta.complete(m);
    _attach(id);
  }

  static Torrent _restoredItem(TorrentClient client, int id) {
    try {
      return Metainfo._decode(
        NativeBridge.torrent.take('read torrent', (o, l) => _TorrentNative.metainfo(client._session, id, o, l)),
      );
    } on NativeException {
      final info =
          _TorrentNative.json('read torrent', (o, l) => _TorrentNative.info(client._session, id, o, l))! as Map;
      return Torrent.parse('magnet:?xt=urn:btih:${info['info_hash']}');
    }
  }

  static Completer<Path> _outcome() {
    final done = Completer<Path>();
    // The client holds what happened to it: a failure nobody awaits is no unhandled error.
    done.future.ignore();
    return done;
  }

  /// A cancel where it was added stops it.
  void _follow() {
    final token = Cancel.token;
    _unlink = token?.onCancel(() => cancel('${token.reason ?? 'cancelled'}'));
  }

  Future<void> _add(Map<String, Object?> options) async {
    final token = _adding = CancelToken();
    final (bytes, isFile) = switch (item) {
      final Metainfo m => (m._bytes, 1),
      final Magnet m => (utf8.encode('${m.uri}'), 0),
    };
    try {
      final (id, _) = await _TorrentNative.call(
        'add ${item._label}',
        token,
        (done) => _TorrentNative.withJson(
          options,
          (op, on) => NativeBridge.torrent.withBytes(
            bytes,
            (p, n) => _TorrentNative.add(client._live, p, n, isFile, op, on, done),
          ),
        ),
      );
      _adding = null;
      if (_status.isFinal) return;
      _attach(id);
    } on CancelledException {
      _adding = null;
    } on Exception catch (e, st) {
      _adding = null;
      _finish(Failed(item, e, st, label: label));
    }
  }

  /// Its engine [id] known: what it is, read once, and its polling started.
  void _attach(int id) {
    _id = id;
    final info =
        _TorrentNative.json('read ${item._label}', (o, l) => _TorrentNative.info(client._session, id, o, l))!
            as Map<String, Object?>;
    final folder = Path(info['folder']! as String);
    final files = (info['files']! as List).cast<List<Object?>>();
    _root = files.length == 1 ? folder / (files.single.first! as String) : folder;
    if (!_meta.isCompleted) {
      try {
        _meta.complete(
          Metainfo._decode(
            NativeBridge.torrent.take('read torrent', (o, l) => _TorrentNative.metainfo(client._session, id, o, l)),
          ),
        );
      } on Exception catch (e, st) {
        _meta.completeError(e, st);
      }
    }
    if (_wantPause) {
      _wantPause = false;
      pause();
    }
    client._watch();
    _read();
    _awaitDone(id);
  }

  /// The engine says when it completes, so `Done` comes then rather than at the next poll.
  void _awaitDone(int id) {
    final stop = _waiting = CancelToken();
    _TorrentNative.call('wait for ${item._label}', stop, (done) => _TorrentNative.wait(client._session, id, done)).then(
      (_) => _read(),
      onError: (Object _) {}, // stopped, or the torrent left the session: the poll has the state
    );
  }

  /// Whether the client polls it: added, not paused, not over.
  bool get _polled => _status is! Paused && !_status.isFinal;

  /// Its state, read from the engine.
  void _read() {
    final id = _id;
    if (id == null || !_polled) return;
    final Map<String, Object?> s;
    try {
      s =
          _TorrentNative.json('read ${item._label}', (o, l) => _TorrentNative.stats(client._live, id, o, l))!
              as Map<String, Object?>;
    } on Exception catch (e, st) {
      return _finish(Failed(item, e, st, label: label));
    }
    final received = s['progress_bytes']! as int, total = s['total_bytes']! as int;
    switch ((s['state'], s['finished'])) {
      case ('error', _):
        final why = '${s['error'] ?? 'unknown error'}';
        _finish(Failed(item, _engine('download ${item._label}', why, path: _root), StackTrace.current, label: label));
      case ('paused', _):
        _set(Paused(item, label: label));
      case ('live', true):
        _finish(Done(item, _root!, label: label));
      case ('live', _):
        _set(Running(item, label: label, received: received, total: total, step: 'downloading'));
        _peers(s);
      case _:
        _set(Running(item, label: label, received: received, total: total, step: 'checking'));
    }
  }

  /// A note once it has had no peer for 30 s while downloading; said again after it had one.
  void _peers(Map<String, Object?> s) {
    final live = switch (s['live']) {
      {'snapshot': {'peer_stats': {'live': final int n}}} => n,
      _ => 0,
    };
    final now = Clock.current.elapsed;
    if (live > 0) {
      _alone = null;
      _toldAlone = false;
    } else if ((_alone ??= now) <= now - const Duration(seconds: 30) && !_toldAlone) {
      _toldAlone = true;
      _warn(const NoteWarning('no peers for 30 s: trackers and DHT found none that answer'));
    }
  }

  // ---- control

  /// Its [Metainfo], once known: at once for a `.torrent`, after the `metadata` step for a magnet.
  Future<Metainfo> get metainfo => _meta.future;

  /// Stops fetching and uploading until [resume]; it is [Paused]. A finished job stays as it is.
  void pause() {
    if (_status is! Running) return;
    final id = _id;
    if (id == null) {
      _wantPause = true;
      return;
    }
    _control(id, 0, 'pause');
    _set(Paused(item, label: label));
  }

  /// Runs it again after a [pause], a [Failed] or a [Stopped] (a new run, a new outcome to
  /// await). Anything else stays as it is.
  void resume() {
    final id = _id;
    if (id == null || (_status is! Paused && _status is! Failed && _status is! Stopped)) return;
    final ended = _status.isFinal;
    _control(id, 1, 'resume');
    _set(Running(item, label: label, step: 'checking', unit: Unit.bytes));
    if (ended) _awaitDone(id);
    client._watch();
  }

  /// Downloads only the files at [indices] from now on: for a magnet, once its [metainfo] has
  /// shown what there is.
  void select(List<int> indices) {
    final id = _id ?? (throw StateError('Cannot select files of ${item._label}: its metadata is not in yet'));
    final code = _TorrentNative.withJson(indices, (p, n) => _TorrentNative.select(client._live, id, p, n));
    if (code < 0) throw _engine('select files of ${item._label}', NativeBridge.torrent.lastError());
  }

  /// Takes it out of the client, stopping it if it runs (it ends [Stopped]); with
  /// [deleteFiles], its files are deleted too.
  Future<void> remove({bool deleteFiles = false}) async {
    _adding?.cancel('removed');
    if (_id case final id? when client._session != nullptr) _control(id, deleteFiles ? 3 : 2, 'remove');
    client._jobs.remove(item.infoHash);
    _halt('removed');
    client._watch();
  }

  /// Stops it: it ends [Stopped] and stays in [TorrentClient.jobs], paused in the engine,
  /// until removed; [resume], or adding it again, runs it again.
  @override
  void cancel([String reason = 'cancelled']) {
    if (_status.isFinal) return;
    _adding?.cancel(reason);
    if (_id case final id? when client._session != nullptr) _control(id, 0, 'stop');
    _halt(reason);
  }

  void _halt(String reason) {
    if (!_status.isFinal) _finish(Stopped(item, reason, label: label));
  }

  void _control(int id, int op, String verb) {
    if (_TorrentNative.control(client._live, id, op) < 0) {
      throw _engine('$verb ${item._label}', NativeBridge.torrent.lastError());
    }
  }

  /// The bytes of file [index] (of [metainfo]'s files) from [start], as they arrive: the pieces
  /// it reaches are fetched first, so a video plays while the rest downloads. It waits for the
  /// metadata and the check of what is on disk; a job that ends first ends it with its error.
  ///
  /// Cancelling the subscription stops the read in flight and frees the reader, even while it
  /// waits for pieces no peer sends; a cancel where it was made ends it with a
  /// [CancelledException].
  Stream<List<int>> read(int index, {int start = 0}) {
    if (index < 0 || start < 0) throw ArgumentError('Invalid read: index $index from $start');
    final outer = Cancel.token;
    final stop = CancelToken();
    void Function()? unlink;
    StreamSubscription<List<int>>? source;
    late final StreamController<List<int>> out;
    out = StreamController(
      onListen: () {
        unlink = outer?.onCancel(() => stop.cancel(outer.reason));
        source = _stream(index, start, stop).listen(
          out.add,
          onError: out.addError,
          onDone: () {
            unlink?.call();
            out.close();
          },
        );
      },
      onPause: () => source?.pause(),
      onResume: () => source?.resume(),
      onCancel: () {
        unlink?.call();
        // First the native read, so the generator is not left awaiting it.
        stop.cancel('read cancelled');
        return source?.cancel().then<void>(
          (_) {},
          onError: (Object e, StackTrace st) => e is CancelledException ? null : Error.throwWithStackTrace(e, st),
        );
      },
    );
    return out.stream;
  }

  Stream<List<int>> _stream(int index, int start, CancelToken token) async* {
    final meta = await _unless(metainfo, token);
    if (index >= meta.files.length) {
      throw ArgumentError.value(index, 'index', 'Invalid file index, expected below ${meta.files.length}');
    }
    await _unless(
      statuses.firstWhere(
        (s) => s.isFinal || s is Running<Torrent, Path> && s.step == 'downloading',
        orElse: () => _status,
      ),
      token,
    );
    switch (_status) {
      case Failed(:final error, :final stackTrace):
        Error.throwWithStackTrace(error, stackTrace);
      case Stopped(:final reason):
        throw CancelledException(reason);
      case _:
    }
    final reader = _TorrentNative.streamOpen(client._live, _id!, index);
    if (reader == nullptr) throw _engine('read ${meta.files[index].path}', NativeBridge.torrent.lastError());
    try {
      if (start > 0 && _TorrentNative.streamSeek(reader, start) < 0) {
        throw _engine('read ${meta.files[index].path}', NativeBridge.torrent.lastError());
      }
      while (true) {
        final (n, bytes) = await _TorrentNative.call(
          'read ${meta.files[index].path}',
          token,
          (d) => _TorrentNative.streamRead(reader, 1 << 20, d, nullptr, nullptr),
        );
        if (n == 0) return;
        yield bytes;
      }
    } finally {
      _TorrentNative.streamFree(reader);
    }
  }

  // ---- statuses

  @override
  String get label => item._label;

  @override
  Status<Torrent, Path> get status => _status;

  @override
  Stream<Status<Torrent, Path>> get statuses {
    late final StreamController<Status<Torrent, Path>> controller;
    controller = StreamController(
      onListen: () {
        _warnings.forEach(controller.add);
        controller.add(_status);
        if (_status.isFinal) {
          controller.close();
        } else {
          _listeners.add(controller);
        }
      },
      onCancel: () => _listeners.remove(controller),
    );
    return controller.stream;
  }

  @override
  Future<Status<Torrent, Path>> get settled => _end.future;

  /// [status], a step on the way, to every listener and to the work it was made in.
  void _set(Status<Torrent, Path> status) {
    if (_status.isFinal && status.isFinal) return;
    final same = switch ((status, _status)) {
      (Running(:final received, :final step), Running(received: final r, step: final s)) => received == r && step == s,
      (Paused(), Paused()) => true,
      _ => false,
    };
    if (same) return;
    // A failed or stopped job that runs again is a new run: a new outcome to await.
    if ((_status is Failed || _status is Stopped) && !status.isFinal) {
      _done = _outcome();
      _end = Completer();
      _warnings.clear();
    }
    _status = status;
    for (final listener in [..._listeners]) {
      listener.add(status);
    }
    if (status case final Running<Torrent, Path> running) _zone.run(() => TaskInternals.report(running));
  }

  void _warn(Warning warning) {
    final status = Warned<Torrent, Path>(item, warning, label: label);
    if (_warnings.length < 100) _warnings.add(status);
    for (final listener in [..._listeners]) {
      listener.add(status);
    }
    _zone.run(() => TaskInternals.warn(warning));
  }

  /// How its run ended: [status], a [Done], [Failed] or [Stopped].
  void _finish(Status<Torrent, Path> status) {
    if (_status.isFinal) return;
    _waiting?.cancel();
    if (_status is Failed) {
      _done = _outcome();
      _end = Completer();
    }
    _status = status;
    for (final listener in [..._listeners]) {
      listener
        ..add(status)
        ..close();
    }
    _listeners.clear();
    if (!_meta.isCompleted) {
      _meta.completeError(switch (status) {
        Failed(:final error) => error,
        Stopped(:final reason) => CancelledException(reason),
        _ => StateError('unreachable'),
      });
    }
    _end.complete(status);
    switch (status) {
      case Done(:final value):
        _unlink?.call();
        _done.complete(value);
      case Failed(:final error, :final stackTrace):
        _done.completeError(error, stackTrace);
      case Stopped(:final reason):
        _unlink?.call();
        _done.completeError(CancelledException(reason));
      case _:
    }
  }

  // ---- Future<Path>: the current run's outcome

  @override
  Stream<Path> asStream() => _done.future.asStream();

  @override
  Future<Path> catchError(Function onError, {bool Function(Object error)? test}) =>
      _done.future.catchError(onError, test: test);

  @override
  Future<R> then<R>(FutureOr<R> Function(Path value) onValue, {Function? onError}) =>
      _done.future.then(onValue, onError: onError);

  @override
  Future<Path> timeout(Duration timeLimit, {FutureOr<Path> Function()? onTimeout}) =>
      _done.future.timeout(timeLimit, onTimeout: onTimeout);

  @override
  Future<Path> whenComplete(FutureOr<void> Function() action) => _done.future.whenComplete(action);

  @override
  String toString() => 'TorrentJob($label, $_status)';
}

/// [future], or a [CancelledException] once [token] is cancelled; what [future] does goes on.
Future<T> _unless<T>(Future<T> future, CancelToken token) {
  if (token.isCancelled) return Future.error(CancelledException.of(token));
  final result = Completer<T>();
  final unlink = token.onCancel(() {
    if (!result.isCompleted) result.completeError(CancelledException.of(token));
  });
  future.then(
    (value) {
      unlink();
      if (!result.isCompleted) result.complete(value);
    },
    onError: (Object error, StackTrace stackTrace) {
      unlink();
      if (!result.isCompleted) result.completeError(error, stackTrace);
    },
  );
  return result.future;
}

/// Magnet links as text.
///
/// {@category Formats}
extension StringTorrentExtensions on String {
  /// This text as a magnet link: [Torrent.parse].
  Magnet get magnet => Torrent.parse(this);
}
