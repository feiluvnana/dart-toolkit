// One user's download (a [Job]), what its runs remember (an [Index]) and
// the files it asks for (a [Download]).
library;

import 'package:dart_toolkit/console.dart';
import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/http.dart';
import 'package:dart_toolkit/json.dart';
import 'package:dart_toolkit/pool.dart';

import 'dashboard.dart';
import 'platform.dart';
import 'queue.dart';

typedef Options = ({bool all, bool reset, bool dry, DateTime? since, int? image, int? video});
typedef Results = List<Outcome<Download, bool>>;

// A file to fetch from [url] or to write [text] into, dated [at] (when posted).
final class Download {
  const Download(this.to, {this.url, this.text, this.at});
  final File to;
  final String? url, text;
  final DateTime? at;
}

// One user's download: what its explorers share. A failed one is reported
// and retried on r.
final class Job {
  Job(this.target, this.kinds, this.api, this.root, this.queue);
  final Target target;
  final Set<Kind> kinds;
  final Client api;
  final Dir root; // downloads/<code>/
  final Queue queue;
  late final u = board.user(target.user, platform: code);
  final batches = <Future<Results>>[];
  Dir? _dir;
  Index? _index;

  Platform get platform => target.platform;
  String get code => platform.code;
  Options get o => queue.o;
  Dir get dir => _dir!;
  Index get index => _index!;

  // Who this is, once the platform looked it up: its folder (the kinds of
  // --reset deleted), its index, and what is on disk. Without [track] (one post) the index is read, never written.
  Future<void> open(String name, {String? id, bool track = true}) async {
    u
      ..name = name
      ..id = id ?? name;
    _dir = root.dir(Fs.sanitize(name));
    if (o.reset && track) await _reset();
    _index = await Index.load(dir, code, dry: o.dry || !track);
    final parts = [
      for (final k in platform.kinds)
        if (kinds.contains(k)) u.parts[k.name] = Part(k.name),
    ];
    await Future.wait([
      for (final p in parts)
        dir
            .dir(p.name)
            .size()
            .then(
              (s) => p
                ..had = s.files
                ..queued = s.files
                ..stored = s.bytes,
            ),
    ]);
  }

  // --reset (asked before the run): the chosen kinds' folders and cursors go,
  // the index stays so carousel numbers stay stable.
  Future<void> _reset() async {
    final gone = [
      for (final k in kinds)
        if (await folder(k).exists()) k,
    ];
    if (gone.isEmpty) return;
    if (o.dry) {
      return board.note('@${u.name}: --reset would delete ${gone.map((k) => k.name).join(', ')}', platform: code);
    }
    for (final k in gone) {
      await folder(k).delete();
      if (await cursor(k).exists()) await cursor(k).delete();
    }
    board.note('@${u.name}: deleted ${gone.map((k) => k.name).join(', ')}', platform: code);
  }

  bool wants(Kind k) => kinds.contains(k);

  Dir folder(Kind k) => dir.dir(k.name);

  Part? part(Kind k) => u.parts[k.name];

  // Where a listing of [k] stopped: `.<code>-cursor-<folder>`.
  File cursor(Kind k) => dir.file('.$code-cursor-${k.name}');

  void phase(Kind k, String what, {bool done = false}) {
    final p = part(k);
    if (p == null) return;
    done ? p.note = what : p.phase = what;
    p.busy = !done;
  }

  void log(Kind k, String line) {
    phase(k, line);
    board.note('@${u.name} ${k.name}: $line', platform: code);
  }

  void changed(String change) {
    u.changes.add(change);
    board.note('@${u.name} changed: $change', platform: code);
  }

  // Whether something posted [at] is wanted (--since).
  bool keep(DateTime at) => o.since == null || !at.isBefore(o.since!);

  // A client for this job on its own [rate], counted and closed with its platform's.
  Client client(Rate rate) => api.copy(rate: rate);

  // A profile picture's first-seen day, its file-name prefix; [change] is noted when it is new.
  String seen(String id, String change) => index.profiles[id] ??= () {
    if (index.profiles.isNotEmpty) changed(change);
    return DateTime.now().format('yyyy-MM-dd');
  }();

  // A profile picture, banner or cover (null: none) into profiles/ as
  // `<first seen>_<id><ext>`, [id] its file name unless given; its change
  // noted when it is new.
  void profile(String? url, String change, {String? id, String ext = ''}) {
    if (url != null) {
      id ??= Fs.sanitize(Uri.parse(url).pathSegments.last);
      add([Download(folder(Kind.profiles).file('${seen(id, change)}_$id$ext'), url: url)]);
      _profiles++;
    }
    phase(Kind.profiles, '$_profiles profile ${_profiles == 1 ? 'asset' : 'assets'}', done: true);
  }

  var _profiles = 0;

  Future<Results> add(List<Download> files) {
    final batch = queue.add(this, files);
    batches.add(batch);
    return batch;
  }

  // Returns the new files.
  Future<int> run() async {
    u.id = null; // on the board: looking up
    try {
      await platform.explore(this);
    } catch (e) {
      u.error = '${platform.explain(e)}';
      board.fail('✗ @${u.name}: ${u.error}', () async {
        u
          ..error = null
          ..parts.clear()
          ..changes.clear();
        batches.clear();
        await run();
      }, platform: code);
      return 0;
    } finally {
      await Future.wait(batches);
      await _index?.save();
    }
    if (u.changes.isNotEmpty) Console.notify('medialoader: @${u.name} changed: ${u.changes.join('; ')}');
    return [for (final b in await Future.wait(batches)) ...b].values().where((isNew) => isNew).length;
  }
}

// What the runs saw, to tell what changed (.<code>.json): when every post
// was last listed, the newest post, every post ever seen with its item ids
// in file-number order, the posts hidden/deleted now, every story and
// profile picture seen, and each highlight's items.
final class Index {
  Index(this.file, Json j, {this.dry = false})
    : checked = DateTime.fromMillisecondsSinceEpoch(j.$('checked').or(0)),
      newest = j.$('newest').or(0),
      posts = {for (final MapEntry(:key, :value) in j.$('posts').asMap<Json>().entries) key: value.asList<String>()},
      hidden = {...j.$('hidden').asList<String>()},
      stories = j.$('stories').asMap<int>(),
      profiles = j.$('profiles').asMap<String>(),
      highlights = {
        for (final MapEntry(:key, :value) in j.$('highlights').asMap<Json>().entries) key: {...value.asList<String>()},
      };

  final File file;
  final bool dry; // --dry-run or one post: never written
  DateTime checked;
  int newest;
  Map<String, List<String>> posts;
  Set<String> hidden;
  Map<String, int> stories;
  Map<String, String> profiles;
  Map<String, Set<String>> highlights;

  static Future<Index> load(Dir dir, String code, {bool dry = false}) async {
    final file = dir.file('.$code.json');
    return Index(file, await file.json(or: Json.of({})), dry: dry);
  }

  Future<void> _saving = Future.value();

  Future<void> save() => dry ? _saving : _saving = _saving.then((_) => _write(), onError: (_) => _write());

  Future<void> _write() => file.write(
    Json.encode({
      'checked': checked.millisecondsSinceEpoch,
      'newest': newest,
      'posts': posts,
      'hidden': [...hidden],
      'stories': stories,
      'profiles': profiles,
      'highlights': {
        for (final e in highlights.entries) e.key: [...e.value],
      },
    }),
  );
}

// The story seen first at [id]'s recorded time (now when new), so a story
// keeps its month however late it is fetched again.
DateTime firstSeen(Index index, String id) =>
    DateTime.fromMillisecondsSinceEpoch((index.stories[id] ??= DateTime.now().millisecondsSinceEpoch ~/ 1000) * 1000);
