/// # Crawling (`net.crawl`)
///
/// The frontier: a queue that feeds itself, plus dedupe, per-host politeness,
/// robots, depth, limit and resume. **That is the whole scope of the type**,
/// and everything else a crawl used to carry is spelled somewhere it already
/// belonged:
///
/// - the transport is a [Send] — a function, not four classes;
/// - a document is a `Codec`, through `Reply.parse`;
/// - the results are a `Flow<Reply>`, so `tap`, `where`, `take`, `flat.map`
///   and the rest of the collection vocabulary are the terminals.
///
/// A single-stage crawl needs none of this and never did:
///
/// ```dart no-compile
/// urls.flow.transform(.map.async(net.http.get, size: 4)).collect(.list());
/// ```
///
/// What [Crawl] adds over that line is the frontier, and only that.
///
/// ```dart
/// final crawl = net.crawl(
///   [Fetch('https://example.test'.url)].seq,
///   (res) => res.parse(format.html).$('a').attrs('href')
///       .transform(.map(res.follow)),
/// )..concurrent(4)..samehost()..depth(3)..limit(500);
///
/// final titles = await crawl.flow
///     .transform(.map((r) => r.parse(format.html).$('h1').text))
///     .collect(.list());
/// ```
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../collection/flow.dart';
import '../collection/collector.dart';
import '../collection/pipe.dart';
import '../collection/sequence.dart';
import '../concurrent/concurrent.dart';
import '../format/format.dart';
import '../src/fs.dart';
import '../src/method.dart';
import '../src/proc.dart';
import 'net.dart';

// ============================================================================
// CRAWLING (net.crawl)
// ============================================================================

/// What a finished crawl counted.
///
/// A record rather than a class, per Rule 4's *a record replaces a variant*:
/// nine mutable fields and a `toJson` were a type, and what a caller wanted
/// from it was six values. The JSON encoding lives on [Crawl.position],
/// which is the only thing that ever needed it.
///
/// `retried` is not here. Retrying happens inside the client, below the
/// scheduler, and a `Send` is a function with nothing to report through —
/// so the number lives where the retrying does, on [Fetcher.retried]. It was
/// counted here through 5.5.0 only because the downloader that did the
/// retrying also owned the loop.
typedef Stats = ({
  /// Replies handled to completion.
  int fetched,

  /// Requests whose fetch or whose `next` threw.
  int failed,

  /// Requests dropped before being handled: `robots.txt` refused them, or
  /// their content type was not among the ones the crawl accepts.
  int skipped,

  /// Total reply bytes seen.
  int bytes,

  /// Wall-clock time from the first fetch.
  Duration elapsed,

  /// Why the crawl stopped early, or `null` when it ran dry on its own.
  String? reason,
});

/// A crawl: a frontier over a [Send].
///
/// Configure it by chaining, then take one of three terminals — [flow] for
/// the replies as they arrive, [settle] for the same with the failures in
/// band, [run] to drain it and read the [stats].
///
/// **Twenty members, where `CrawlBuilder` alone had 45.** The ones that went
/// were not deleted so much as relocated: the client knobs to [Fetcher], the
/// routing to a `switch`, the terminals to the collection vocabulary, and the
/// parsers to `format`.
///
/// **Nothing is fetched until something collects.** The workers start in the
/// flow's `onListen` and stop when it is cancelled, so `crawl.flow` built and
/// thrown away costs nothing, and `crawl.flow.collect(.first())` fetches one
/// page.
final class Crawl {
  /// Creates a crawl seeded with [seeds].
  ///
  /// [next] is a pure function from a reply to the requests that follow it —
  /// reply in, requests out — which is why it is testable with a
  /// `Reply.text` fixture and no crawl at all. It replaces the handler, the
  /// router and the tag table together, because Dart's `switch` is a better
  /// router than three public members:
  ///
  /// ```dart no-compile
  /// net.crawl([Fetch(seed)].seq, (res) => switch (res.fetch.tag) {
  ///   null     => res.parse(format.html).$('.artist a').attrs('href')
  ///                  .transform(.map((h) => res.follow(h, tag: 'artist'))),
  ///   'artist' => res.parse(format.html).$('.album a').attrs('href')
  ///                  .transform(.map((h) => res.follow(h, tag: 'album'))),
  ///   _        => const Sequence<Fetch>([]),
  /// });
  /// ```
  ///
  /// It hands back a [Sequence], which is the one rule for a callback
  /// anywhere in this library: **what a callback gives the library back is a
  /// `Sequence`** — here, in `Transformer.flat.map` and in `Pipe.flat.map`.
  /// A literal crosses with `.seq`; everything this library returns is one
  /// already, so `res.follow` composed through `transform(.map(...))` needs
  /// no conversion at all.
  ///
  /// Omitting [next] crawls exactly the seeds, which is what `net.http.sync`
  /// is for when there is no politeness or dedupe to want.
  Crawl(Sequence<Fetch> seeds, [this._next])
    : _seeds = seeds.transform(.cast<Fetch>()).collect(.list());

  final List<Fetch> _seeds;
  final Sequence<Fetch> Function(Reply res)? _next;

  Send? _send;
  int _concurrency = 4;
  Duration _gap = Duration.zero;
  bool _perhost = false;
  int? _limit;
  int? _depth;
  final List<Pattern> _allow = [];
  final List<Pattern> _deny = [];
  final List<String> _accept = [];
  bool _samehost = false;
  bool _dedupe = true;
  String? _agent;
  String? _resumePath;
  Duration _resumeEvery = const Duration(seconds: 5);

  // --- Runtime state ------------------------------------------------------

  final _Frontier _queue = _Frontier();
  final Set<Fetch> _inflight = <Fetch>{};
  final Set<String> _seen = <String>{};
  final Map<String, Future<Robots>> _robots = {};
  final Map<String, DateTime> _nextHostAccess = {};
  final Set<Completer<void>> _waiting = {};
  String? _seedHost;
  int _active = 0;
  bool _started = false;
  bool _stopped = false;
  DateTime? _began;
  DateTime? _ended;
  String? _reason;

  int _fetched = 0;
  int _failed = 0;
  int _skipped = 0;
  int _bytes = 0;
  int _scheduled = 0;

  static const int _hostTableLimit = 4096;
  static const int _robotsCacheLimit = 1024;

  // --- Configuration ------------------------------------------------------

  /// Answers this crawl's requests through [send], instead of `net.http`.
  ///
  /// The transport seam. A [Fetcher] is a [Send], so a client with its own
  /// headers, timeout, retries, cap, cache and limiter is configured **once,
  /// where those knobs are declared** — which is why none of them is a
  /// member here:
  ///
  /// ```dart no-compile
  /// net.crawl(seeds, next)
  ///    .using(Fetcher(
  ///      headers: {'User-Agent': 'ExampleBot/1.0'},
  ///      timeout: 10.s,
  ///      retries: 3,   // a crawl over the default client does not retry
  ///      cap: util.size.parse('5MiB')!,
  ///      cache: HttpCache('.cache'),
  ///      limiter: concurrent.rate(10, per: 1.s),
  ///    ))
  ///    .concurrent(4);
  /// ```
  ///
  /// Through 5.5.0 ten of those knobs were declared at four levels — builder,
  /// engine, downloader and client — thirty-two declarations in all, and a
  /// caller-supplied downloader silently dropped five of them. A knob that
  /// lives in one place cannot be dropped in transit.
  Crawl using(Send send) {
    _send = send;
    return this;
  }

  /// Runs at most [count] fetches at once. Minimum one.
  Crawl concurrent(int count) {
    _concurrency = count > 0 ? count : 1;
    return this;
  }

  /// Pauses [gap] after each fetch, for politeness.
  ///
  /// Set [perhost] to pace each host separately rather than the crawl as a
  /// whole — which is what a broad crawl wants, since a global pause slows
  /// every host down to protect one.
  Crawl delay(Duration gap, {bool perhost = false}) {
    _gap = gap;
    _perhost = perhost;
    return this;
  }

  /// Stops after [count] replies have been handled.
  Crawl limit(int count) {
    _limit = count > 0 ? count : 1;
    return this;
  }

  /// Follows at most [hops] links away from a seed.
  Crawl depth(int hops) {
    _depth = hops >= 0 ? hops : 0;
    return this;
  }

  /// Only fetches URLs matching [pattern]. Additive.
  Crawl allow(Pattern pattern) {
    _allow.add(pattern);
    return this;
  }

  /// Never fetches URLs matching [pattern]. Additive.
  Crawl deny(Pattern pattern) {
    _deny.add(pattern);
    return this;
  }

  /// Restricts the crawl to the host of the first seed.
  Crawl samehost([bool enabled = true]) {
    _samehost = enabled;
    return this;
  }

  /// Only handles replies of these content [types].
  ///
  /// **Two things, deliberately.** The types go out as the `Accept` header
  /// and a reply that arrives as something else anyway is skipped before
  /// `next` sees it. They are two halves of one intent — *only give me HTML*
  /// — and splitting them would mean setting a header in one place and a
  /// filter in another, where they can drift apart.
  ///
  /// Entries are MIME types, optionally with a `/*` wildcard on the subtype.
  /// A reply carrying no `Content-Type` matches nothing.
  Crawl accept(Sequence<String> types) {
    _accept.addAll(
      types
          .transform(.cast<String>())
          .transform(.map((type) => type.toLowerCase()))
          .collect(.list()),
    );
    return this;
  }

  /// Drops a request whose URL, method, tag and body were already seen.
  Crawl dedupe([bool enabled = true]) {
    _dedupe = enabled;
    return this;
  }

  /// Obeys each host's `robots.txt`, as [agent].
  ///
  /// `Crawl-delay` is honoured as a per-host floor whether or not [delay]
  /// asked for per-host pacing. It was `.robots(bool, agent)` through 5.5.0,
  /// which is Rule 4's *the flag is not the lookup*: calling the member is
  /// the flag.
  ///
  /// `/robots.txt` is fetched through this crawl's own [Send], so politeness
  /// works against a fixture transport — which `Robots.load` could not do,
  /// because it reached for the shared client itself.
  Crawl obey([String agent = '*']) {
    _agent = agent;
    return this;
  }

  /// Saves the crawl's position to [path], and picks it up again from there.
  ///
  /// An interrupted crawl otherwise starts over. On the way in an existing
  /// [path] is restored — the frontier, the visited set and the counters, so
  /// [limit] still counts the whole crawl rather than this leg of it. On the
  /// way out the file is written every [every], once more when the run stops,
  /// and once more again if the process is interrupted; a crawl that finishes
  /// on its own deletes it, having nothing left to resume.
  ///
  /// Requests carry [Fetch.meta] through the file, so anything stored there
  /// has to be JSON-encodable.
  Crawl resume(String path, {Duration every = const Duration(seconds: 5)}) {
    _resumePath = path;
    if (every > Duration.zero) _resumeEvery = every;
    return this;
  }

  // --- Position -----------------------------------------------------------

  /// The version of the serialized [position] this class writes and reads.
  static const int version = 1;

  /// What this crawl has left to do, as JSON.
  ///
  /// The frontier, the visited set and the counters. [resume] writes this to
  /// a file for you; this is the member for keeping it anywhere else — a
  /// row in a database, `io.dictionary`, a queue.
  ///
  /// A request counts as pending until `next` has run for its reply, so
  /// nothing that was mid-fetch is lost.
  Map<String, Object?> get position => {
    'version': version,
    'pending': [
      for (final fetch in [..._inflight, ..._queue.all]) fetch.toJson(),
    ],
    'seen': _seen.toList(),
    'stats': {
      'fetched': _fetched,
      'failed': _failed,
      'skipped': _skipped,
      'bytes': _bytes,
      'scheduled': _scheduled,
      if (_reason != null) 'reason': _reason,
    },
  };

  /// Puts a [position] back, before the crawl starts.
  ///
  /// Pending requests go straight into the frontier: they were recorded in
  /// the visited set when first scheduled, so routing them through the
  /// scope checks would see them as duplicates and drop every one.
  ///
  /// Throws [FormatException] when [position] was written by a newer
  /// [version], rather than restoring half a frontier. Throws [StateError]
  /// once the crawl has started.
  void restore(Map<String, Object?> position) {
    if (_started) throw StateError('Cannot restore a crawl that has started');
    final found = (position['version'] as num? ?? version).toInt();
    if (found > version) {
      throw FormatException(
        'Crawl position version $found is newer than the supported $version',
      );
    }
    _seen
      ..clear()
      ..addAll((position['seen'] as List? ?? const []).cast<String>());
    final stats = (position['stats'] as Map? ?? const {})
        .cast<String, Object?>();
    int count(String key) => (stats[key] as num? ?? 0).toInt();
    _fetched = count('fetched');
    _failed = count('failed');
    _skipped = count('skipped');
    _bytes = count('bytes');
    _scheduled = count('scheduled');
    for (final entry in (position['pending'] as List? ?? const [])) {
      _queue.add(Fetch.fromJson((entry as Map).cast<String, Object?>()));
    }
  }

  /// What the crawl has counted so far, or in total once it is finished.
  Stats get stats => (
    fetched: _fetched,
    failed: _failed,
    skipped: _skipped,
    bytes: _bytes,
    elapsed: _began == null
        ? Duration.zero
        : (_ended ?? DateTime.now()).difference(_began!),
    reason: _reason,
  );

  // --- Terminals ----------------------------------------------------------

  /// The replies, as they arrive.
  ///
  /// **The terminal.** Everything the 5.5.0 builder offered as a member is a
  /// step on this flow:
  ///
  /// | was | is |
  /// | :--- | :--- |
  /// | `on.progress(fn)` | `.transform(.tap(fn))` |
  /// | `on.item(fn)` | the flow itself |
  /// | `on.done(fn)` | the line after; [stats] |
  /// | `on.error(fn)` | [settle] |
  /// | `res.emit(item)` | what the caller does with the reply |
  /// | `res.stop(reason)` | `.transform(.take.when(test))` |
  /// | `crawl.items()` | `.collect(.list())` |
  /// | `crawl.gather(map)` | `.transform(.flat.map(map)).collect(.list())` |
  /// | `crawl.save(path)` | `io.async.lines.write(path, …)` |
  ///
  /// A request that failed is counted in `stats.failed` and does not reach
  /// this flow — one bad page does not end a crawl. [settle] is the terminal
  /// that reports them.
  ///
  /// Cancelling stops the crawl, so `.collect(.first())` fetches one page.
  Flow<Reply> get flow => Flow<Reply>.of(
    () => _open()
        .where((outcome) => outcome is Done<Reply>)
        .map((outcome) => (outcome as Done<Reply>).value),
  );

  /// The replies and the failures, in band.
  ///
  /// One [Settled] per request that was served: [Done] carrying the reply,
  /// [Broke] carrying what was thrown. The same outcome type `concurrent`
  /// uses, which is the one-directional dependency Rule 2 allows.
  ///
  /// ```dart no-compile
  /// await crawl.settle.collect(.foreach((outcome) => switch (outcome) {
  ///   Done(:final value) => save(value),
  ///   Broke(:final error) => log.warn('$error'),
  /// }));
  /// ```
  Flow<Settled<Reply>> get settle => Flow<Settled<Reply>>.of(_open);

  /// Drains the crawl and reports what it counted.
  ///
  /// One line over [flow]: `await flow.collect(.drain())`, then [stats]. The
  /// shorthand for a crawl whose point is the side effects `next` had, or
  /// the files a [Send] wrote.
  Future<Stats> run() async {
    await flow.collect(Pour.foreach((_) {}));
    return stats;
  }

  /// Stops the crawl once in-flight work settles, recording [reason].
  ///
  /// Cancelling [flow] does this for you, which is the ordinary way. This is
  /// the door for a caller holding the crawl rather than the flow.
  void stop([String reason = 'Stopped']) {
    _stopped = true;
    _reason ??= reason;
    _signal();
  }

  // --- The loop -----------------------------------------------------------

  /// Opens a run: seeds the frontier, starts the workers, and reports every
  /// outcome.
  Stream<Settled<Reply>> _open() {
    late final StreamController<Settled<Reply>> controller;
    var running = false;
    Completer<void>? resumed;

    void wake() {
      final waiter = resumed;
      resumed = null;
      if (waiter != null && !waiter.isCompleted) waiter.complete();
    }

    Future<void> begin() async {
      running = true;
      _started = true;
      _began = DateTime.now();
      final Send send = _send ?? net.http.call;

      try {
        // Setting up is the crawl's work too, so a resume file that cannot be
        // read reaches the terminal rather than being thrown from a timer
        // callback nobody is awaiting.
        _restoreFile();
        for (final seed in _seeds) {
          _schedule(seed);
        }
        _arm();
        await Future.wait([
          for (var i = 0; i < _concurrency; i++)
            _worker(send, controller, () => resumed?.future),
        ]);
      } catch (error, stack) {
        if (!controller.isClosed) controller.addError(error, stack);
      } finally {
        _ended = DateTime.now();
        await _disarm();
        if (!controller.isClosed) await controller.close();
      }
    }

    controller = StreamController<Settled<Reply>>(
      // A single-subscription controller reports itself paused until someone
      // listens, so nothing is fetched for a flow nobody collects.
      onListen: () {
        if (!running) unawaited(begin());
      },
      // A terminal that stops early ends the crawl. A terminal that ran to
      // the end has nothing to cancel, and saying so would put a `reason` on
      // a crawl that simply ran dry.
      onCancel: () {
        wake();
        if (_ended == null) stop('Flow cancelled');
      },
      // A consumer that stops reading stops the crawl fetching, rather than
      // buffering a frontier's worth of replies nobody has asked for.
      onPause: () => resumed ??= Completer<void>(),
      onResume: wake,
    );
    return controller.stream;
  }

  /// Pulls requests until the frontier drains or the crawl stops.
  Future<void> _worker(
    Send send,
    StreamController<Settled<Reply>> sink,
    Future<void>? Function() paused,
  ) async {
    while (!_stopped) {
      // Give a terminal that just took its last element the turn it needs to
      // cancel, before another page is served on its behalf.
      await Future<void>.delayed(Duration.zero);
      await paused();
      if (_stopped) break;

      final fetch = _queue.serve();
      if (fetch == null) {
        // Nothing queued: either the run is finished, or a busy sibling may
        // still discover more work.
        if (_idle) break;
        await _wait();
        continue;
      }
      _inflight.add(fetch);

      var robotsGap = Duration.zero;
      final agent = _agent;
      if (agent != null && _isWeb(fetch.url)) {
        final rules = await _rules(send, fetch.url);
        if (!rules.allowed(fetch.url, agent: agent)) {
          _skip(fetch);
          continue;
        }
        robotsGap = rules.delay(agent: agent) ?? Duration.zero;
      }

      // A Crawl-delay the site asked for is honoured per-host whether or not
      // per-host pacing was requested; it is a floor, not a replacement.
      final hostGap = _perhost && _gap > robotsGap ? _gap : robotsGap;
      if (hostGap > Duration.zero && !_stopped) {
        await _throttle(fetch.url.host, hostGap);
      }

      _active++;
      try {
        final reply = await send(fetch);
        if (_stopped) continue;
        _bytes += reply.bytes.length;

        if (_accept.isNotEmpty && !_accepts(reply.type)) {
          // A PDF, an image, an archive: fetched, but not what was asked
          // for. Dropped here rather than inside every caller.
          _skip(fetch);
          continue;
        }

        final followed = _next?.call(reply);
        if (followed != null) {
          followed.collect(Collector.foreach<Fetch>(_schedule));
        }

        _inflight.remove(fetch);
        _fetched++;
        if (!sink.isClosed) sink.add(Done<Reply>(reply));
        if (_limit != null && _fetched >= _limit!) {
          stop('Limit of $_limit pages reached');
        }
      } catch (error, stack) {
        _failed++;
        if (!sink.isClosed) sink.add(Broke<Reply>(error, stack));
      } finally {
        _active--;
        if (_idle) _signal();
      }

      if (!_perhost && _gap > Duration.zero && !_stopped) {
        await Future<void>.delayed(_gap);
      }
    }
  }

  bool get _idle => _active == 0 && _queue.isEmpty;

  /// Pushes [fetch] into the frontier, unless the crawl's scope refuses it.
  void _schedule(Fetch fetch) {
    if (_stopped) return;
    if (_limit != null && _scheduled >= _limit!) return;

    if (_seedHost == null && fetch.url.host.isNotEmpty) {
      _seedHost = fetch.url.host.toLowerCase();
    }
    if (_depth != null && fetch.depth > _depth!) return;
    if (_samehost &&
        _seedHost != null &&
        fetch.url.host.isNotEmpty &&
        fetch.url.host.toLowerCase() != _seedHost) {
      return;
    }

    final text = fetch.url.toString();
    if (_deny.any((pattern) => pattern.allMatches(text).isNotEmpty)) return;
    if (_allow.isNotEmpty &&
        !_allow.any((pattern) => pattern.allMatches(text).isNotEmpty)) {
      return;
    }
    if (_dedupe && fetch.dedupe && !_seen.add(_key(fetch))) return;

    // The header half of [accept]. `putIfAbsent`, so a request that names its
    // own `Accept` — or a client that does — keeps it.
    if (_accept.isNotEmpty &&
        !fetch.headers.keys.any((key) => key.toLowerCase() == 'accept')) {
      fetch.headers['Accept'] = _accept.join(', ');
    }

    _queue.add(fetch);
    _scheduled++;
    _signal();
  }

  void _skip(Fetch fetch) {
    _inflight.remove(fetch);
    _skipped++;
    if (_idle) _signal();
  }

  /// Whether [type] is one of the [accept] entries.
  bool _accepts(String? type) {
    if (type == null) return false;
    for (final wanted in _accept) {
      if (wanted == type) return true;
      if (wanted.endsWith('/*') &&
          type.startsWith(wanted.substring(0, wanted.length - 1))) {
        return true;
      }
    }
    return false;
  }

  static bool _isWeb(Uri url) => url.scheme == 'http' || url.scheme == 'https';

  /// The `robots.txt` for [url]'s origin, fetched through [send] once.
  ///
  /// The pending fetch is cached, not just its result, so workers arriving at
  /// a new host together share one request instead of each issuing their own.
  Future<Robots> _rules(Send send, Uri url) {
    final origin =
        '${url.scheme}://${url.host.toLowerCase()}'
        '${url.hasPort ? ':${url.port}' : ''}';
    final cached = _robots.remove(origin);
    // Reinserting on every hit orders the map least-recently-used, so a host
    // the crawl keeps returning to is not evicted ahead of one seen once.
    if (cached != null) return _robots[origin] = cached;
    if (_robots.length >= _robotsCacheLimit) {
      _robots.remove(_robots.keys.first);
    }
    return _robots[origin] = _loadRobots(send, Uri.parse('$origin/robots.txt'));
  }

  /// Reads `/robots.txt` through [send], per RFC 9309 section 2.3.1.
  ///
  /// **2xx** — the rules in the body apply. **4xx** — the host has no rules,
  /// so everything is allowed. **5xx** — the rules are unreachable rather
  /// than absent, so crawling is disallowed outright: a server having a bad
  /// day is not an invitation.
  ///
  /// A transport error — DNS, a refused connection, a timeout — is treated as
  /// 4xx. That is a deliberate departure: the RFC's *unreachable* case is
  /// about a server that answered badly, and stopping a whole crawl over one
  /// failed lookup costs more than it protects.
  static Future<Robots> _loadRobots(Send send, Uri url) async {
    Reply? reply;
    try {
      reply = await send(Fetch(url));
    } on Object {
      // A lookup that never reached a server is not a server saying no.
      return Robots();
    }
    if (reply.ok) return reply.parse(format.robots);
    return reply.status >= 500 ? Robots.closed : Robots();
  }

  /// Waits until at least [gap] has passed since the last request to [host].
  Future<void> _throttle(String host, Duration gap) async {
    final now = DateTime.now();
    final scheduled = _nextHostAccess.remove(host);
    final target = (scheduled != null && scheduled.isAfter(now))
        ? scheduled
        : now;
    if (scheduled == null && _nextHostAccess.length >= _hostTableLimit) {
      // A broad crawl meets more hosts than it needs to remember. Removing
      // and reinserting above makes this least-recently-used, so the entry
      // dropped is the host longest untouched rather than the one seen first.
      _nextHostAccess.remove(_nextHostAccess.keys.first);
    }
    _nextHostAccess[host] = target.add(gap);
    final wait = target.difference(now);
    if (wait > Duration.zero) await Future<void>.delayed(wait);
  }

  /// Releases every worker parked in [_wait] so they re-check their state.
  void _signal() {
    if (_waiting.isEmpty) return;
    final released = _waiting.toList();
    _waiting.clear();
    for (final completer in released) {
      if (!completer.isCompleted) completer.complete();
    }
  }

  /// Parks until work is queued, the crawl drains, or it stops.
  Future<void> _wait() {
    if (_queue.isNotEmpty || _stopped || _idle) return Future<void>.value();
    final completer = Completer<void>();
    _waiting.add(completer);
    return completer.future;
  }

  /// The dedupe key: method, normalised URL, tag and body.
  ///
  /// The fragment is dropped, the host lower-cased, query parameters sorted
  /// and a trailing slash ignored, so the same page reached three ways is one
  /// request.
  static String _key(Fetch fetch) {
    final bare = fetch.url.removeFragment();
    final host = bare.host.toLowerCase();
    var path = bare.path;
    if (path.length > 1 && path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    final sorted = bare.queryParametersAll.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final query = Map.fromEntries(sorted);
    final url = bare
        .replace(
          host: host.isNotEmpty ? host : null,
          path: path,
          queryParameters: query.isEmpty ? null : query,
        )
        .toString();
    final body = fetch.body?.bytes();
    final digest =
        (fetch.method != HttpMethod.get && body != null && body.isNotEmpty)
        ? md5.convert(body).toString()
        : '';
    return '${fetch.method.wire}|$url|${fetch.tag ?? ''}|$digest';
  }

  // --- Resume -------------------------------------------------------------

  Timer? _resumeTimer;
  FutureOr<void> Function()? _resumeHook;
  Future<void> _resumeWrites = Future<void>.value();

  /// Reads the saved position at [_resumePath], if there is one.
  ///
  /// A file that is there but unreadable throws: the caller asked to carry on
  /// from it, and quietly starting over would throw away the very progress
  /// they were protecting.
  void _restoreFile() {
    final path = _resumePath;
    if (path == null) return;
    final file = File(path);
    if (!file.existsSync()) return;
    final Object? decoded;
    try {
      decoded = jsonDecode(file.readAsStringSync());
    } on FormatException catch (error) {
      throw FormatException('Resume file $path is not valid JSON: $error');
    }
    if (decoded is! Map) {
      throw FormatException('Resume file $path does not hold a position');
    }
    _started = false;
    restore(decoded.cast<String, Object?>());
    _started = true;
  }

  /// Starts saving the position: on a timer, and on interruption.
  void _arm() {
    final path = _resumePath;
    if (path == null) return;
    _resumeTimer = Timer.periodic(_resumeEvery, (_) {
      // A periodic save is best effort. Letting a full disk throw from a
      // timer callback would take down the isolate mid-crawl, which is worse
      // than a position that is a few seconds stale.
      _save(path).catchError((Object _) {});
    });
    // Ctrl-C and `kill` both reach this, so an interrupted crawl saves the
    // position it actually reached rather than the last tick's.
    final hook = _resumeHook = () => _save(path);
    Exit.hook(hook);
  }

  /// Stops saving, writes the final position, and clears the file when there
  /// is nothing left to resume.
  Future<void> _disarm() async {
    final path = _resumePath;
    if (path == null) return;
    _resumeTimer?.cancel();
    _resumeTimer = null;
    final hook = _resumeHook;
    if (hook != null) {
      // The hook holds the signal watcher, and so the process, open. Leaving
      // it registered would hang every script that finished a resumable
      // crawl.
      Exit.unhook(hook);
      _resumeHook = null;
    }

    final saved = position;
    if (_stopped || (saved['pending'] as List).isNotEmpty) {
      await _save(path);
      return;
    }
    // Every page handled: there is no position left worth keeping.
    await _resumeWrites;
    final file = File(path);
    if (file.existsSync()) await file.delete();
  }

  /// Writes the position to [path], behind any write already in flight.
  Future<void> _save(String path) {
    final json = position;
    return _resumeWrites = _resumeWrites.then(
      (_) => Fs.dump(path, json, pretty: false),
    );
  }
}

/// A bucketed FIFO priority frontier.
///
/// One queue per [Fetch.priority], kept in descending priority order, so
/// serving is O(log buckets) and ties keep the order they were scheduled in.
class _Frontier {
  final SplayTreeMap<int, ListQueue<Fetch>> _buckets =
      SplayTreeMap<int, ListQueue<Fetch>>((a, b) => b.compareTo(a));
  int _count = 0;

  bool get isEmpty => _count == 0;
  bool get isNotEmpty => _count > 0;

  void add(Fetch fetch) {
    _buckets.putIfAbsent(fetch.priority, ListQueue<Fetch>.new).add(fetch);
    _count++;
  }

  Fetch? serve() {
    while (_buckets.isNotEmpty) {
      final key = _buckets.firstKey();
      if (key == null) return null;
      final queue = _buckets[key];
      if (queue != null && queue.isNotEmpty) {
        _count--;
        return queue.removeFirst();
      }
      _buckets.remove(key);
    }
    return null;
  }

  /// Everything waiting, in the order [serve] would hand it out.
  Iterable<Fetch> get all => [for (final queue in _buckets.values) ...queue];
}
