/// # Crawling ([crawl])
///
/// The frontier: a queue that feeds itself, plus dedupe, per-host politeness,
/// robots, depth, limit and resume. **That is the whole scope of the type**,
/// and everything else a crawl used to carry is spelled somewhere it already
/// belonged:
///
/// - the transport is a [Send] — a function, not four classes;
/// - a document is a `DocumentFormat`, through `Response.parse`;
/// - the results are a `Stream<Response>`, because [Crawler] *is* one, so
///   `where`, `take`, `expand`, `map` and the rest of `Stream` are the
///   terminals.
///
/// A single-stage crawl needs none of this and never did:
///
/// ```dart
/// await urls.parallelMap(Http.get, concurrency: 4);
/// ```
///
/// What [Crawler] adds over that line is the frontier, and only that.
///
/// ```dart
/// final crawler = crawl(
///   ['https://example.test'],
///   next: (res) => res.$('a').attrs('href').map(res.follow),
///   concurrency: 4,
///   scope: .sameHost,
///   depth: 3,
///   limit: 500,
/// );
///
/// final titles = await crawler.map((r) => r.$('h1').text).toList();
/// ```
/// {@category Crawling}
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../concurrent/concurrent.dart';
import '../format/format.dart';
import '../src/fs.dart';
import '../src/proc.dart';
import 'net.dart';

// ============================================================================
// CRAWLING (crawl)
// ============================================================================

/// What a finished crawl counted.
///
/// A record rather than a class — a record replaces a variant:
/// nine mutable fields and a `toJson` were a type, and what a caller wanted
/// from it was six values. The JSON encoding lives on [Crawler.position],
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

// ============================================================================
// CRAWL POLICY (Politeness, Scope, RobotsPolicy)
// ============================================================================

/// How long a crawl waits between fetches.
///
/// Reached with a leading dot wherever a crawl is configured, because the
/// parameter type supplies the prefix:
///
/// ```dart
/// crawl(seeds, politeness: .perHost(250.ms));
/// ```
final class Politeness {
  const Politeness.every(this.gap) : perHost = false;

  /// Paces each host separately rather than the crawl as a whole.
  ///
  /// What a broad crawl wants: a global pause slows every host down to
  /// protect one.
  const Politeness.perHost(this.gap) : perHost = true;

  /// Fetch as fast as the concurrency allows.
  static const Politeness none = Politeness.every(Duration.zero);

  /// How long to pause.
  final Duration gap;

  /// Whether [gap] is counted per host or across the crawl.
  final bool perHost;

  @override
  String toString() => gap == Duration.zero
      ? 'Politeness.none'
      : 'Politeness($gap, perHost: $perHost)';
}

/// How far from its first seed a crawl may wander.
///
/// ```dart
/// crawl(seeds, scope: .sameHost);
/// ```
enum Scope {
  /// Follow a link anywhere.
  anywhere,

  /// Only follow links on the first seed's host, whatever the scheme or port.
  sameHost,

  /// Only follow links with the first seed's scheme, host *and* port.
  sameOrigin;

  /// Whether [url] is inside this scope, given the crawl's first [seed].
  bool admits(Uri url, Uri? seed) {
    if (seed == null || url.host.isEmpty) return true;
    return switch (this) {
      anywhere => true,
      sameHost => url.host.toLowerCase() == seed.host.toLowerCase(),
      sameOrigin =>
        url.host.toLowerCase() == seed.host.toLowerCase() &&
            url.scheme == seed.scheme &&
            url.port == seed.port,
    };
  }
}

/// Whether a crawl obeys each host's `robots.txt`, and as whom.
///
/// ```dart
/// crawl(seeds, robots: .obey('ExampleBot/1.0'));
/// ```
///
/// `Crawl-delay` is honoured as a per-host floor whether or not the crawl's
/// [Politeness] asked for per-host pacing.
///
/// `/robots.txt` is fetched through the crawl's own [Send], so politeness
/// works against a fixture transport — which `Robots.load` could not do,
/// because it reached for the shared client itself.
final class RobotsPolicy {
  /// Obeys `robots.txt`, identifying as [agent].
  const RobotsPolicy.obey([this.agent = '*']);

  const RobotsPolicy._() : agent = null;

  /// Fetches whatever the frontier holds, asking no one.
  static const RobotsPolicy ignore = RobotsPolicy._();

  /// The user agent whose rules apply, or `null` when `robots.txt` is ignored.
  final String? agent;

  @override
  String toString() =>
      agent == null ? 'RobotsPolicy.ignore' : 'RobotsPolicy.obey($agent)';
}

/// A crawl: a frontier over a [Send].
///
/// Configure it by chaining, then take one of three terminals — the stream itself for
/// the replies as they arrive, `Iterable.settle` for the same with the failures in
/// band, [run] to drain it and read the [stats].
///
/// **Twenty members, where `CrawlBuilder` alone had 45.** The ones that went
/// were not deleted so much as relocated: the client knobs to [Fetcher], the
/// routing to a `switch`, the terminals to the collection vocabulary, and the
/// parsers to `format`.
///
/// **Nothing is fetched until something listens.** The workers start in the
/// stream's `onListen` and stop when it is cancelled, so a crawl built and
/// thrown away costs nothing, and `crawler.first` fetches exactly one page.
final class Crawler extends Stream<Response> {
  /// Creates a crawl seeded with [seeds].
  ///
  /// **Every knob is a named argument.** Through 8.1.0 they were eleven
  /// cascade methods — `..concurrent(8)..delay(250.ms)..sameHost()` — which
  /// meant an editor could not show you what a crawl could be told, the
  /// defaults were invisible, and the fields stayed writable for the object's
  /// whole life even though changing one after the first fetch did nothing
  /// coherent. A signature answers all three.
  ///
  /// [next] is a pure function from a reply to the requests that follow it —
  /// reply in, requests out — which is why it is testable with a
  /// `Response.text` fixture and no crawl at all. It replaces the handler, the
  /// router and the tag table together, because Dart's `switch` is a better
  /// router than three public members:
  ///
  /// ```dart
  /// crawl(seeds, next: (res) => switch (res.fetch.tag) {
  ///   null     => res.$$('.artist a').map((a) => res.follow(a.attr('href')!, tag: 'artist')),
  ///   'artist' => res.$$('.album a').map((a) => res.follow(a.attr('href')!, tag: 'album')),
  ///   _        => const <Fetch>[],
  /// });
  /// ```
  ///
  /// Omitting [next] crawls exactly the seeds, which is what a bare fetch
  /// is for when there is no politeness or dedupe to want.
  Crawler(
    Iterable<Fetch> seeds, {
    Iterable<Fetch> Function(Response res)? next,
    int concurrency = 4,
    Politeness politeness = Politeness.none,
    Scope scope = Scope.anywhere,
    RobotsPolicy robots = RobotsPolicy.ignore,
    int? depth,
    int? limit,
    Iterable<Pattern> allow = const [],
    Iterable<Pattern> deny = const [],
    Iterable<String> accept = const [],
    bool dedupe = true,
    String? resume,
    Duration resumeEvery = const Duration(seconds: 5),
    Send? send,
  }) : _seeds = seeds.cast<Fetch>().toList(),
       _next = next,
       _concurrency = concurrency > 0 ? concurrency : 1,
       _politeness = politeness,
       _scope = scope,
       _robotsPolicy = robots,
       _depth = depth == null ? null : (depth >= 0 ? depth : 0),
       _limit = limit == null ? null : (limit > 0 ? limit : 1),
       _allow = allow.toList(),
       _deny = deny.toList(),
       _accept = [for (final type in accept) type.toLowerCase()],
       _dedupe = dedupe,
       _resumePath = resume,
       _resumeEvery = resumeEvery > Duration.zero
           ? resumeEvery
           : const Duration(seconds: 5),
       _send = send;

  final List<Fetch> _seeds;
  final Iterable<Fetch> Function(Response res)? _next;

  /// The transport this crawl answers its requests through.
  ///
  /// A [Fetcher] is a [Send], so a client with its own headers, timeout,
  /// retries, cap, cache and limiter is configured **once, where those knobs
  /// are declared** — which is why none of them is an argument here:
  ///
  /// ```dart
  /// crawl(seeds, next: next, concurrency: 4, send: Fetcher(
  ///   headers: {'User-Agent': 'ExampleBot/1.0'},
  ///   timeout: 10.s,
  ///   retries: 3,   // a crawl over the default client does not retry
  ///   cap: 5.mb.toInt(),
  ///   cache: HttpCache('.cache'),
  ///   limiter: RateLimiter(10, per: 1.s),
  /// ).call);
  /// ```
  final Send? _send;

  /// At most this many fetches run at once.
  final int _concurrency;

  /// How long to pause between fetches, and whether per host.
  final Politeness _politeness;

  /// How far from the first seed's host the crawl may wander.
  final Scope _scope;

  /// Whether each host's `robots.txt` is obeyed, and as whom.
  final RobotsPolicy _robotsPolicy;

  /// At most this many hops away from a seed.
  final int? _depth;

  /// Stop after this many replies have been handled.
  final int? _limit;

  /// Only fetch URLs matching one of these. Empty allows everything.
  final List<Pattern> _allow;

  /// Never fetch a URL matching one of these.
  final List<Pattern> _deny;

  /// Only handle replies of these content types.
  ///
  /// **Two things, deliberately.** The types go out as the `Accept` header
  /// and a reply that arrives as something else anyway is skipped before
  /// `next` sees it. They are two halves of one intent — *only give me HTML*
  /// — and splitting them would mean setting a header in one place and a
  /// filter in another, where they can drift apart.
  ///
  /// Entries are MIME types, optionally with a `/*` wildcard on the subtype.
  /// A reply carrying no `Content-Type` matches nothing.
  final List<String> _accept;

  /// Whether a request whose URL, method, tag and body were already seen is
  /// dropped.
  final bool _dedupe;

  /// Where the crawl's position is saved, and picked up again from.
  ///
  /// An interrupted crawl otherwise starts over. On the way in an existing
  /// file is restored — the frontier, the visited set and the counters, so
  /// `limit` still counts the whole crawl rather than this leg of it. On the
  /// way out the file is written every `resumeEvery`, once more when the run
  /// stops, and once more again if the process is interrupted; a crawl that
  /// finishes on its own deletes it, having nothing left to resume.
  ///
  /// Requests carry [Fetch.meta] through the file, so anything stored there
  /// has to be JSON-encodable.
  final String? _resumePath;

  /// How often the position is written while the crawl runs.
  final Duration _resumeEvery;

  // --- Runtime state ------------------------------------------------------

  final _Frontier _queue = _Frontier();
  final Set<Fetch> _inflight = <Fetch>{};
  final Set<String> _seen = <String>{};
  final Map<String, Future<Robots>> _robots = {};
  final Map<String, DateTime> _nextHostAccess = {};
  final Set<Completer<void>> _waiting = {};
  Uri? _seedOrigin;
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

  static const int _hostTableLimit = 4_096;
  static const int _robotsCacheLimit = 1_024;

  // --- Position -----------------------------------------------------------

  /// The version of the serialized [position] this class writes and reads.
  static const int version = 1;

  /// What this crawl has left to do, as JSON.
  ///
  /// The frontier, the visited set and the counters. [resume] writes this to
  /// a file for you; this is the member for keeping it anywhere else — a
  /// row in a database, a queue.
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
        'Crawler position version $found is newer than the supported $version',
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
  /// **The crawl is the stream.** A [Crawler] `extends Stream<Response>`, so
  /// every `Stream` member works on it directly and there is nothing to reach
  /// through:
  ///
  /// ```dart
  /// await for (final res in crawl(seeds, next: next)) print(res.url);
  ///
  /// final titles = await crawl(seeds, next: next)
  ///     .expand((res) => res.$$('h1').map((h) => h.text))
  ///     .toList();
  /// ```
  ///
  /// It carried `.flow` and `.stream` as well through 8.1.0 — three spellings
  /// of one stream, two of which existed only because the third was not
  /// believed.
  ///
  /// A request that failed is counted in `stats.failed` and does not reach
  /// the stream — one bad page does not end a crawl. `Iterable.settle` is the terminal
  /// that reports them.
  ///
  /// **Nothing is fetched until something listens.** Cancelling stops the
  /// crawl, so `.first` fetches exactly one page.
  @override
  StreamSubscription<Response> listen(
    void Function(Response event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _replies.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  Stream<Response> get _replies => _open()
      .where((outcome) => outcome is Done<Response>)
      .map((outcome) => (outcome as Done<Response>).value);

  /// The replies and the failures, in band.
  Stream<Settled<Response>> get settle => _open();

  /// Drains the crawl and reports what it counted.
  Future<Stats> run() async {
    await _replies.drain<void>();
    return stats;
  }

  /// Stops the crawl once in-flight work settles, recording [reason].
  ///
  /// Cancelling the stream itself does this for you, which is the ordinary way. This is
  /// the door for a caller holding the crawl rather than the flow.
  void stop([String reason = 'Stopped']) {
    _stopped = true;
    _reason ??= reason;
    _signal();
  }

  // --- The loop -----------------------------------------------------------

  /// Opens a run: seeds the frontier, starts the workers, and reports every
  /// outcome.
  Stream<Settled<Response>> _open() {
    late final StreamController<Settled<Response>> controller;
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
      final Send send = _send ?? Http.client.call;

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

    controller = StreamController<Settled<Response>>(
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
    StreamController<Settled<Response>> sink,
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
      final agent = _robotsPolicy.agent;
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
      final gap = _politeness.gap;
      final hostGap = _politeness.perHost && gap > robotsGap ? gap : robotsGap;
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
          for (final f in followed) {
            _schedule(f);
          }
        }

        _inflight.remove(fetch);
        _fetched++;
        if (!sink.isClosed) sink.add(Done<Response>(reply));
        if (_limit case final cap? when _fetched >= cap) {
          stop('Limit of $cap pages reached');
        }
      } catch (error, stack) {
        _failed++;
        if (!sink.isClosed) sink.add(Broke<Response>(error, stack));
      } finally {
        _active--;
        if (_idle) _signal();
      }

      if (!_politeness.perHost &&
          _politeness.gap > Duration.zero &&
          !_stopped) {
        await Future<void>.delayed(_politeness.gap);
      }
    }
  }

  bool get _idle => _active == 0 && _queue.isEmpty;

  /// Pushes [fetch] into the frontier, unless the crawl's scope refuses it.
  void _schedule(Fetch fetch) {
    if (_stopped) return;
    if (_limit case final cap? when _scheduled >= cap) return;

    if (_seedOrigin == null && fetch.url.host.isNotEmpty) {
      _seedOrigin = fetch.url;
    }
    if (_depth case final hops? when fetch.depth > hops) return;
    if (!_scope.admits(fetch.url, _seedOrigin)) return;

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

  /// The `robots.txt` for [url]'s origin, fetched through [Http.send] once.
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

  /// Reads `/robots.txt` through [Http.send], per RFC 9309 section 2.3.1.
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
    Response? reply;
    try {
      reply = await send(Fetch(url));
    } on Object {
      // A lookup that never reached a server is not a server saying no.
      return Robots();
    }
    if (reply.ok) return reply.text.parse(.robots);
    return reply.statusCode >= 500 ? Robots.closed : Robots();
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
