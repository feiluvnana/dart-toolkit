import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

import '../fs/fs.dart';
import 'engine.dart';
import 'selector.dart';

// ============================================================================
// PIPELINE REQUEST, RESPONSE, SCHEDULER & ROUTER
// ============================================================================

class Request<T> {
  final Uri url;
  final String method;
  final Map<String, String> headers;
  final Object? body;
  final int priority;
  final String? tag;
  final Map<String, dynamic> meta;
  Engine<T>? engine;

  Request(
    dynamic url, {
    this.method = 'GET',
    Map<String, String>? headers,
    this.body,
    this.priority = 0,
    this.tag,
    Map<String, dynamic>? meta,
    this.engine,
  })  : url = url is Uri ? url : Uri.parse(url.toString()),
        headers = headers ?? {},
        meta = meta ?? {};

  factory Request.get(
    dynamic url, {
    Map<String, String>? headers,
    int priority = 0,
    String? tag,
    Map<String, dynamic>? meta,
  }) =>
      Request(
        url,
        method: 'GET',
        headers: headers,
        priority: priority,
        tag: tag,
        meta: meta,
      );

  factory Request.post(
    dynamic url, {
    Object? body,
    Map<String, String>? headers,
    int priority = 0,
    String? tag,
    Map<String, dynamic>? meta,
  }) =>
      Request(
        url,
        method: 'POST',
        body: body,
        headers: headers,
        priority: priority,
        tag: tag,
        meta: meta,
      );

  @override
  String toString() => '$method $url';
}

class Response<T> {
  final Request<T> request;
  final int status;
  final Map<String, String> headers;
  final List<int> bytes;
  Engine<T>? engine;

  String? _body;
  Document? _doc;

  Response({
    required this.request,
    this.status = 200,
    Map<String, String>? headers,
    List<int>? bytes,
    this.engine,
  })  : headers = headers ?? {},
        bytes = bytes ?? const [];

  bool get ok => status >= 200 && status < 300;
  String get body => _body ??= utf8.decode(bytes, allowMalformed: true);
  dynamic get json => jsonDecode(body);
  Document get doc => _doc ??= html_parser.parse(body);

  QueryResult $(String selector) => QueryResult(doc.querySelectorAll(selector));

  String? link([Pattern? filter]) => links(filter).firstOrNull;

  List<String> links([Pattern? filter]) {
    final raw = QueryResult([doc.documentElement ?? doc.body ?? Element.tag('body')]).links(filter);
    return raw.map((h) => request.url.resolve(h).toString()).toList();
  }

  String? src([Pattern? filter]) => srcs(filter).firstOrNull;

  List<String> srcs([Pattern? filter]) {
    final raw = QueryResult([doc.documentElement ?? doc.body ?? Element.tag('body')]).srcs(filter);
    return raw.map((s) => request.url.resolve(s).toString()).toList();
  }

  Uri get url => request.url;
  Map<String, dynamic> get meta => request.meta;
  String? get tag => request.tag;

  List<String> get lines => QueryResult([doc.documentElement ?? doc.body ?? Element.tag('body')]).lines;

  void emit(T item) {
    if (engine == null) throw StateError('No engine attached to this response');
    engine!.emit(item);
  }

  void add(dynamic urlOrReq) {
    if (engine == null) throw StateError('No engine attached to this response');
    engine!.add(urlOrReq);
  }

  void follow(
    dynamic url, {
    String? tag,
    Map<String, dynamic>? meta,
    int priority = 0,
  }) {
    if (engine == null) throw StateError('No engine attached to this response');
    final target = url is Uri ? url : request.url.resolve(url.toString());
    engine!.add(Request<T>.get(target, tag: tag, meta: meta, priority: priority));
  }

  void stop([String reason = 'Stopped']) => engine?.stop(reason);

  Future<void> save(
    dynamic filePath, [
    dynamic sourceUrl,
    String part = '.part',
  ]) async {
    if (sourceUrl != null) {
      final resolved = request.url.resolve(sourceUrl.toString());
      if (engine != null) {
        await engine!.downloader.save(filePath, resolved, part: part);
      } else {
        await Fs.download(resolved, filePath is File ? filePath : File(filePath.toString()), part: part);
      }
    } else {
      final file = filePath is File ? filePath : File(filePath.toString());
      await Fs.write(file, bytes, part: part);
    }
  }

  @override
  String toString() => '$status ${request.url} (${bytes.length} bytes)';
}

class Scheduler<T> {
  final List<Request<T>> _queue = [];
  final Set<String> _visited = <String>{};
  final bool dedupe;
  final bool priority;

  Engine<T>? engine;

  Scheduler({this.dedupe = true, this.priority = false});

  void attach(Engine<T> engine) {
    this.engine = engine;
  }

  void add(dynamic requestOrUrl) {
    final req = requestOrUrl is Request<T>
        ? requestOrUrl
        : Request<T>.get(requestOrUrl);

    final key = '${req.method}:${_norm(req.url)}';
    if (!dedupe || _visited.add(key)) {
      if (engine != null) {
        req.engine = engine;
      }
      _queue.add(req);
      if (priority && _queue.length > 1) {
        _queue.sort((a, b) => b.priority.compareTo(a.priority));
      }
    }
  }

  Request<T>? next() {
    if (_queue.isEmpty) return null;
    return _queue.removeAt(0);
  }

  int get length => _queue.length;
  bool get isEmpty => _queue.isEmpty;
  bool get isNotEmpty => _queue.isNotEmpty;

  void clear() => _queue.clear();
  void reset() => _visited.clear();

  static String _norm(Uri uri) {
    final n = uri.removeFragment();
    var p = n.path;
    if (p.length > 1 && p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    return n.replace(path: p).toString();
  }
}

class Priority<T> extends Scheduler<T> {
  Priority({super.dedupe = true}) : super(priority: true);
}

typedef Process<T> = FutureOr<void> Function(
  Response<T> response,
  Engine<T> engine,
);

class Router<T> {
  final List<_Rule<T>> _rules = [];
  Process<T>? _fallback;
  Engine<T>? engine;

  void attach(Engine<T> engine) {
    this.engine = engine;
  }

  bool get isNotEmpty => _rules.isNotEmpty || _fallback != null;
  bool get isEmpty => !isNotEmpty;
  int get length => _rules.length;

  Router<T> on(Pattern pattern, Process<T> handler) {
    _rules.add(
      _Rule<T>(
        test: (res) => pattern.allMatches(res.request.url.toString()).isNotEmpty,
        handler: handler,
      ),
    );
    return this;
  }

  Router<T> tag(String name, Process<T> handler) {
    _rules.add(
      _Rule<T>(
        test: (res) => res.request.tag == name,
        handler: handler,
      ),
    );
    return this;
  }

  Router<T> status(int code, Process<T> handler) {
    _rules.add(
      _Rule<T>(
        test: (res) => res.status == code,
        handler: handler,
      ),
    );
    return this;
  }

  Router<T> fallback(Process<T> handler) {
    _fallback = handler;
    return this;
  }

  Future<void> call(Response<T> response, Engine<T> engine) async {
    for (final rule in _rules) {
      if (rule.test(response)) {
        await rule.handler(response, engine);
        return;
      }
    }
    if (_fallback != null) {
      await _fallback!(response, engine);
    }
  }
}

class _Rule<T> {
  final bool Function(Response<T> res) test;
  final Process<T> handler;

  _Rule({required this.test, required this.handler});
}
