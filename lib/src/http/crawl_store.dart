// What a crawl keeps in its `store:`: one JSON line per event (a page queued `q`, with its id
// and everything needed to send it again; a key visited `v`; a page done `d`; the page count
// `p`), appended in a batch about once a second and when it stops. What was queued and never
// done is the frontier. Opening it rewrites it compacted, so it never outgrows one run.

part of '../../scrape.dart';

/// The version of what [_Journal] writes; another is a [FormatException] naming the store.
const _journalVersion = 1;

final class _Journal {
  final Store store;
  final int Function() pages;
  final _batch = StringBuffer();
  Timer? _timer;
  var _next = 0;
  var _closed = false;
  Future<void> _writing = Future.value();

  _Journal(this.store, this.pages);

  static const _name = 'crawl.jsonl';

  String? get _file => store.folder == null ? null : '${store.folder}${Platform.pathSeparator}$_name';

  Map<String, String>? get _memory => StoreInternals.memory(store);

  String get _key => '${StoreInternals.prefix(store)}$_name';

  /// What the store holds: the visited keys, the page count and the frontier, oldest first, or
  /// `null` when it holds no crawl. A last line cut off by a crash is ignored; anything else
  /// unreadable is a [FormatException] naming the store.
  Future<({Set<int> visited, int pages, List<Map<String, Object?>> frontier})?> read() async {
    final String text;
    if (_file case final path?) {
      final file = File(path);
      if (!await file.exists()) return null;
      text = await file.readAsString();
    } else {
      final kept = _memory?[_key];
      if (kept == null) return null;
      text = kept;
    }
    final visited = <int>{};
    final frontier = <int, Map<String, Object?>>{};
    var pages = 0;
    final lines = text.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.isEmpty) continue;
      final Object? entry;
      try {
        entry = jsonDecode(line);
        if (entry is! Map) throw const FormatException('expected a JSON object per line');
      } on FormatException catch (e) {
        if (i == lines.length - 1 && i > 0) break; // the line a crash cut short
        throw FormatException('Invalid crawl store in $store, line ${i + 1}: ${e.message}');
      }
      if (i == 0) {
        if (entry['crawl'] != _journalVersion) {
          throw FormatException('Invalid crawl store in $store: version ${entry['crawl']}, expected $_journalVersion');
        }
        continue;
      }
      switch (entry) {
        case {'q': final int id}:
          frontier[id] = entry.cast<String, Object?>();
          if (entry['k'] case final int key) visited.add(key);
        case {'v': final int key}:
          visited.add(key);
        case {'v': final List<Object?> keys}:
          visited.addAll(keys.whereType<int>());
        case {'d': final int id}:
          frontier.remove(id);
        case {'p': final int count}:
          pages = count;
      }
    }
    return (visited: visited, pages: pages, frontier: frontier.values.toList());
  }

  /// Writes [visited], the page count and [frontier] as the whole store, then appends from there;
  /// answers the ids [frontier] got.
  Future<List<int>> start(Set<int> visited, List<Map<String, Object?>> frontier) async {
    final out = StringBuffer()
      ..writeln(jsonEncode({'crawl': _journalVersion}))
      ..writeln(jsonEncode({'v': visited.toList()}))
      ..writeln(jsonEncode({'p': pages()}));
    final ids = <int>[];
    for (final item in frontier) {
      ids.add(_next);
      out.writeln(jsonEncode({...item, 'q': _next++}..remove('k')));
    }
    if (_file case final path?) {
      await FileBridge.write(path, utf8.encode('$out'));
    } else {
      _memory?[_key] = '$out';
    }
    return ids;
  }

  /// [entry] queued, with its visited [key]; answers its id.
  int queued(Map<String, Object?> entry, int? key) {
    final id = _next++;
    _write({'q': id, 'k': ?key, ...entry});
    return id;
  }

  void visited(int key) => _write({'v': key});

  void done(int id) => _write({'d': id});

  void _write(Map<String, Object?> entry) {
    // After [close] the crawl is over: what a page cut short does next is not news.
    if (_closed) return;
    _batch.writeln(jsonEncode(entry));
    _timer ??= Timer(const Duration(seconds: 1), flush);
  }

  /// Appends what is batched, with the page count.
  void flush() {
    _timer?.cancel();
    _timer = null;
    if (_batch.isEmpty) return;
    _batch.writeln(jsonEncode({'p': pages()}));
    final text = '$_batch';
    _batch.clear();
    if (_file case final path?) {
      _writing = _writing.then((_) => File(path).writeAsString(text, mode: FileMode.append, flush: true));
    } else {
      final memory = _memory;
      if (memory != null) memory[_key] = '${memory[_key] ?? ''}$text';
    }
  }

  /// Flushes and stops: what comes after is not kept.
  Future<void> close() async {
    flush();
    _closed = true;
    await _writing;
  }

  /// Forgets the crawl: it finished.
  Future<void> erase() async {
    await close();
    if (_file case final path?) {
      try {
        await File(path).delete();
      } on PathNotFoundException catch (_) {} // never written: nothing to forget
    } else {
      _memory?.remove(_key);
    }
  }
}
