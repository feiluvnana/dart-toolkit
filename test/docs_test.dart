/// Compiles every `dart` snippet in the documentation.
///
/// NAMESPACE.md step 7 has said since 1.x that a stale example fails the
/// build, and for a long time nothing checked one. The pass filtered to whole
/// programs — `if (!snippet.contains('void main(')) continue;` — which was a
/// tenth of the blocks and none of the ones in `///` comments under `lib/`.
/// Everything else was unchecked, and the drift was already there: 35 doc
/// comments across 12 files named API that 4.0.0 had deleted.
///
/// 5.5.0 retired the `docs/` folder. The `///` comments under `lib/` are the
/// documentation now — they are where the reasoning already lived, they
/// reach the reader through dartdoc and through the editor, and they cannot
/// drift from the signature they sit above. This harness compiles every
/// snippet in them, plus the ones in `README.md`, `NAMESPACE.md` and
/// `example/README.md`.
///
/// Most documentation snippets are fragments that assume a `res`, a `page`, a
/// `seed`. That is the right way to write a doc, so the harness supplies the
/// context rather than the doc having to become a program: every fragment is
/// wrapped in a `main` with the fixtures below in scope as top-level getters,
/// which a snippet's own `final res = ...` shadows without complaint.
///
/// Two escape hatches, both meant to be rare:
///
/// - ```` ```dart no-compile ```` — for a block that is deliberately not
///   compilable: an interface sketch, a before/after migration table, a
///   snippet whose point is that it does *not* work. Every use is a line
///   somebody has to justify.
/// - `// setup: <dart>` as the first lines of a block — extra declarations
///   prepended before the body, for a fragment that needs one specific thing
///   the shared fixtures do not carry.
library;

import 'dart:io';

import 'package:test/test.dart';

/// Where the snippets are written for `dart analyze` to read.
const _outDir = '.dart_tool/doc_snippets';

/// Files whose `dart` blocks are compiled.
List<File> _markdown() => [
  File('README.md'),
  File('NAMESPACE.md'),
  File('example/README.md'),
];

/// Dart sources whose `///` comments hold snippets.
List<File> _sources() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'))
    .toList();

/// The context every fragment is compiled against.
///
/// Top-level getters, not locals: a snippet that declares its own `res` or
/// `page` shadows one of these legally, where a local would be a duplicate
/// declaration. Unused getters raise nothing, so one fixture set serves every
/// snippet.
const _fixtures = r'''
// ---------------------------------------------------------------------------
// Fixtures. See the library doc comment in test/docs_test.dart.
// ---------------------------------------------------------------------------
const _html = '<html><body><h1 class="title">Title</h1>'
    '<div class="row"><span class="name">A</span>'
    '<span class="price">1.20</span></div>'
    '<a class="link" href="/next">Next</a>'
    '<form id="login" action="/session" method="post">'
    '<input type="hidden" name="csrf" value="tok">'
    '<input type="text" name="user"></form></body></html>';

Uri get seed => Uri.parse('https://example.com');
Uri get url => seed;
Uri get sitemapUrl => Uri.parse('https://example.com/sitemap.xml');
// One fixture answers both the `net.http` snippets that read a response and
// the `net.crawl` ones that call `follow` or read `fetch.meta` on it —
// `Page<T>` folded into `Reply` in 6.0.0.
Reply get res => Reply(
  url: seed,
  fetch: Fetch(seed),
  status: 200,
  bytes: utf8.encode(_html),
  headers: const {'content-type': 'text/html'},
);
Reply get reply => res;
Markup get page => format.html.parse(_html);
Markup get markup => page;
Markup get card => page.$('.row');
Markup get row => card;
Json get doc => format.json.parse('{"data":{"items":[{"sku":"a"}],"total":1}}');
Json get config => doc;
Json get pubspec => doc;
String get path => 'out/file.txt';
String get dir => 'out';
String get dest => 'out/copy.txt';
String get text => 'some text';
String get body => _html;
String get template => 'Hello {name}';
String get user => 'ada';
String get pass => 'secret';
const Slot<String> token = Slot<String>('token');
const Slot<int> visits = Slot<int>('visits');
String get name => 'widget';
String get selector => '.row';
String get href => '/next';
String get src => '/img.png';
int get size => 4;
int get port => 8080;
Duration get timeout => const Duration(seconds: 5);
ConsoleLogger get log => system.console.logger;
ConsoleWriter get writer => system.console.writer;
Fetcher get client => Fetcher();
Fetcher get session => Fetcher(session: true);
Map<String, Object?> get db => io.dictionary('out/state.json');
Iterable<Uri> get urls => [seed].seq;
Iterable<Row> get rows => const [Row('a.com', 1, 1)];
Iterable<String> get titles => const ['One'];
List<String> get paths => const ['a.txt'];
Iterable<String> get items => titles;
Iterable<Map<String, String>> get records =>
    const [{'name': 'Ada', 'amount': '1'}];
Map<String, num> get spend => const {'a.com': 1};
Map<String, List<Row>> get hosts =>
    rows.collect(.group.by((r) => r.host));
Map<String, Object?> get vars => const {'name': 'widget'};
Map<String, Object?> get data => vars;
List<String> get args => const ['--force'];
List<int> get bytes => const [1, 2, 3];

/// A stand-in row type, for the grouping and reducing examples.
class Row {
  const Row(this.host, this.cost, this.score);
  final String host;
  final num cost;
  final num score;
  bool get live => true;
  bool get ok => true;
  String get name => 'widget';
  String get text => 'text';
  num get price => 1;
  Uri get url => Uri.parse('https://a.com/1');
  String get id => 'a';
  String get sku => 'a';
  num get qty => 1;
  DateTime get seen => DateTime(2026, 1, 1);
}

Progress get bar => Progress(total: 10, message: 'Working');
Spinner get spin => Spinner();
Table get table => Table(headers: const ['a', 'b']);
Robots get robots =>
    format.robots.parse('User-agent: *\nDisallow: /private');
Pool<Uri> get pool => Pool<Uri>(size: 4);
Limiter get limit => concurrent.rate(10, per: const Duration(seconds: 1));
Semaphore get gate => concurrent.semaphore(2);
Iterable<FileSystemEntry> get files => io.dir.walk('out', only: .file);
Iterable<String> get agents => const ['MyBot'];
Csv get csvsheet => format.csv.parse('a,b\n1,2\n');
Send get mock => (f) async => Reply.text(_html, fetch: f);
Opt<bool> get force => cli.flag('force');
Opt<bool> get verbose => cli.flag('verbose');
Opt<int> get concurrency => cli.number('concurrency', def: 4);
Slot<String> get slot => const Slot<String>('name');
IOSink get sink => stdout;
File get file => File('out/file.txt');
String get html => _html;
String get markupText => _html;
String get secret => 'shh';
String get runId => 'run-1';
Uri get searchUrl => Uri.parse('https://example.com/search');
DateTime get publishedAt => DateTime(2026, 1, 1);
DateTime get referenceAt => DateTime(2026, 1, 2);
SysResult get result => const SysResult(code: 0, out: '', err: '');
List<String> get list => const ['a', 'b'];
Row get item => const Row('a.com', 1, 1);
Row get t => item;
Row get a => item;
Uri get u => seed;

/// A stand-in for a snippet's own model type.
class Item {
  const Item(this.sku);
  final String sku;
  static Item from(Markup m) => Item(m.attr('data-sku') ?? '');
}

/// A stand-in for a snippet's own configuration type.
class Config {
  const Config(this.name);
  final String name;
  static Config fromJson(Object? raw) => const Config('widget');
}

/// A stand-in for a snippet's own enum.
enum Mode { fast, slow, debug }

Form get form => page.form('#login')!.at(seed);
Crawl get crawl => net.crawl([Fetch(seed)].seq)..using(mock);
Asked? get req => null;
Process get process => throw UnimplementedError();

Row parse(String line) => const Row('a.com', 1, 1);
Future<int> _build(Cli cli) async => 0;
Future<int> build(Cli cli) async => 0;
Future<void> commit(List<String> paths) async {}
Future<void> enrich(Row row) async {}
Future<Object?> worker(String input) async => input;
Future<Reply> fetch(Uri u) => Fetcher().send(.get, u);
Future<void> rebuild([String? out, int concurrency = 1]) async {}
Iterable<Fetch> next(Reply res) => const <Fetch>[];
Object? heavyComputation(Object? input) => input;
Future<Object?> fetchFromFlakyService() async => null;
Future<Object?> mayThrow() async => null;
Future<Object?> expensiveWork() async => null;
Future<void> work() async {}
Future<void> save(Object? value) async {}
Future<void> send(Object? value) async {}
const Slot<int> track = Slot<int>('track');
DateTime? since() => null;
''';

/// One extracted snippet, ready to be written out.
class _Snippet {
  _Snippet(this.origin, this.code);

  /// Where it came from, for the failure message.
  final String origin;

  /// The whole compilable program.
  final String code;
}

/// The `dart` fenced blocks in [text], with their opening-fence info string.
Iterable<({String info, String body})> _fences(String text) {
  final normalized = text.replaceAll('\r', '');
  final pattern = RegExp(
    r'^ {0,3}```dart([^\n]*)\n(.*?)^ {0,3}```',
    multiLine: true,
    dotAll: true,
  );
  return pattern
      .allMatches(normalized)
      .map((m) => (info: m.group(1)!.trim(), body: m.group(2)!));
}

/// The `dart` blocks inside `///` comments in a Dart source.
Iterable<({String info, String body})> _docFences(String source) {
  final blocks = <({String info, String body})>[];
  final lines = source.replaceAll('\r', '').split('\n');
  var open = false;
  var info = '';
  var body = <String>[];
  for (final line in lines) {
    final comment = RegExp(r'^\s*///\s?(.*)$').firstMatch(line);
    if (comment == null) {
      // A doc comment that ends mid-block is a block that never closed; drop
      // it rather than guessing where it stopped.
      open = false;
      body = [];
      continue;
    }
    final content = comment.group(1)!;
    final fence = RegExp(r'^\s*```(.*)$').firstMatch(content);
    if (fence != null) {
      if (open) {
        blocks.add((info: info, body: '${body.join('\n')}\n'));
        open = false;
        body = [];
      } else if (fence.group(1)!.trim().startsWith('dart')) {
        open = true;
        info = fence.group(1)!.trim().substring('dart'.length).trim();
      }
      continue;
    }
    if (open) body.add(content);
  }
  return blocks;
}

/// Whether [body] is already a whole program.
bool _isProgram(String body) => RegExp(
  r'^\s*(void|Future<void>|Future<int>)\s+main\s*\(',
  multiLine: true,
).hasMatch(body);

/// [body] wrapped into a program that can be analyzed.
///
/// The fragment is split into top-level *chunks* — a run of lines that starts
/// at brace depth zero and ends when the depth comes back to zero — and each
/// chunk is filed as a declaration or a statement. Declarations are hoisted
/// beside the fixtures; statements become the body of `main`. Chunking rather
/// than line-matching is what keeps a multi-line `await net.crawl(...)` chain
/// from being mistaken for a function declaration because its first line
/// happens to end in `{`.
String _wrap(String body) {
  final setup = <String>[];
  final imports = <String>[];
  final top = <String>[];
  final statements = <String>[];

  // `// setup:` lines, wherever they appear: a block that opens with its own
  // imports would otherwise have to put them somewhere odd.
  final lines = <String>[];
  for (final line in body.split('\n')) {
    final m = RegExp(r'^\s*//\s*setup:\s?(.*)$').firstMatch(line);
    if (m != null) {
      setup.add(m.group(1)!);
    } else {
      lines.add(line);
    }
  }

  for (final chunk in _chunks(lines)) {
    // The first line that is neither blank nor a comment: a chunk carries any
    // doc comment or blank run that preceded it, so `chunk.first` is often not
    // the thing being classified.
    final first = chunk
        .map((l) => l.trim())
        .firstWhere(
          (l) => l.isNotEmpty && !l.startsWith('//'),
          orElse: () => '',
        );
    if (first.startsWith('import ') || first.startsWith('export ')) {
      imports.add(first);
    } else if (_declares(first)) {
      top.addAll(chunk);
    } else {
      statements.addAll(chunk);
    }
  }

  return [
    '// ignore_for_file: unused_local_variable, unused_element, unused_import,',
    '// ignore_for_file: avoid_print, unnecessary_statements, dead_code,',
    '// ignore_for_file: unused_field, avoid_dynamic_calls, unreachable_from_main,',
    '// ignore_for_file: prefer_const_declarations, omit_local_variable_types,',
    '// ignore_for_file: strict_raw_type, inference_failure_on_collection_literal,',
    '// ignore_for_file: unnecessary_lambdas, avoid_unused_constructor_parameters',
    "import 'dart:async';",
    "import 'package:test/test.dart';",
    "import 'dart:convert';",
    "import 'dart:io';",
    "import 'package:dart_toolkit/dart_toolkit.dart';",
    "import 'package:dart_toolkit/html.dart';",
    ...imports,
    '',
    _fixtures,
    ...top,
    '',
    'void main() async {',
    ...setup,
    ...statements,
    '}',
  ].join('\n');
}

/// [lines] grouped into runs that each start and end at brace depth zero.
///
/// A blank line or a comment run at depth zero joins the chunk that follows,
/// so a doc comment stays attached to what it documents.
List<List<String>> _chunks(List<String> lines) {
  final chunks = <List<String>>[];
  var current = <String>[];
  var depth = 0;
  for (final line in lines) {
    current.add(line);
    depth += _delta(line);
    final trimmed = line.trim();
    if (depth <= 0 &&
        (trimmed.endsWith('}') ||
            trimmed.endsWith(';') ||
            trimmed.endsWith(',') ||
            trimmed.endsWith(']'))) {
      chunks.add(current);
      current = <String>[];
      depth = 0;
    }
  }
  if (current.isNotEmpty) chunks.add(current);

  // Fold a chunk that is only comments or blanks into the next one.
  final folded = <List<String>>[];
  var pending = <String>[];
  for (final chunk in chunks) {
    final code = chunk.where(
      (l) => l.trim().isNotEmpty && !l.trim().startsWith('//'),
    );
    if (code.isEmpty) {
      pending.addAll(chunk);
      continue;
    }
    folded.add([...pending, ...chunk]);
    pending = <String>[];
  }
  if (pending.isNotEmpty) folded.add(pending);
  return folded;
}

/// Whether a chunk beginning with [first] declares something top-level.
bool _declares(String first) {
  if (RegExp(
    r'^(abstract\s+|final\s+|sealed\s+|base\s+|interface\s+|external\s+)*'
    r'(class|enum|typedef|extension|mixin)\b',
  ).hasMatch(first)) {
    return true;
  }
  // A function or a top-level variable: a type, a name, then `(` or `=`.
  // Anything that opens with a statement keyword is not one, and neither is
  // anything that starts with a receiver — `await`, `res.`, `.collect`.
  if (RegExp(
    r'^(await|return|if|for|while|do|switch|try|throw|assert|yield|break|'
    r'continue|else|case|default|print|expect)\b',
  ).hasMatch(first)) {
    return false;
  }
  if (first.startsWith('.') || first.startsWith('}') || first.startsWith(')')) {
    return false;
  }
  // A type, a space, a name, then a parameter list — followed by a body,
  // either a block or an arrow. The arrow may be on the same line and end in
  // `;`, which is how a one-line helper is written.
  return RegExp(
        r'^[A-Za-z_][\w<>,?\s\[\].]*\s+[a-z_$][\w$]*\s*\(',
      ).hasMatch(first) &&
      (first.endsWith('{') || first.contains('=>'));
}

/// A snippet that is already a whole program, with the imports it assumes.
String _program(String body) {
  final head = [
    '// ignore_for_file: unused_local_variable, unused_import, avoid_print,',
    '// ignore_for_file: unnecessary_statements, unreachable_from_main',
    if (!body.contains('package:dart_toolkit/dart_toolkit.dart'))
      "import 'package:dart_toolkit/dart_toolkit.dart';",
    if (!body.contains('package:dart_toolkit/html.dart'))
      "import 'package:dart_toolkit/html.dart';",
  ];
  return '${head.join('\n')}\n$body';
}

int _delta(String line) {
  var d = 0;
  for (final ch in line.split('')) {
    if (ch == '{' || ch == '(' || ch == '[') d++;
    if (ch == '}' || ch == ')' || ch == ']') d--;
  }
  return d;
}

void main() {
  group('documentation', () {
    test(
      'every dart snippet in lib///, README and NAMESPACE compiles',
      () async {
        final snippets = <_Snippet>[];
        var skipped = 0;

        void collect(
          String origin,
          Iterable<({String info, String body})> fences,
        ) {
          var n = 0;
          for (final fence in fences) {
            n++;
            if (fence.info.contains('no-compile')) {
              skipped++;
              continue;
            }
            final code = _isProgram(fence.body)
                ? _program(fence.body)
                : _wrap(fence.body);
            snippets.add(_Snippet('$origin block $n', code));
          }
        }

        for (final file in _markdown()) {
          if (!file.existsSync()) continue;
          collect(file.path, _fences(file.readAsStringSync()));
        }
        for (final file in _sources()) {
          collect(file.path, _docFences(file.readAsStringSync()));
        }

        // The point of the whole exercise: if this number collapses, the
        // harness has stopped looking rather than the docs having shrunk.
        // 5.5.0 retired `docs/`, so the floor moved with it: 255 snippets
        // in `///` comments, README, NAMESPACE and example/README, where
        // the folder used to carry another hundred and thirty saying the
        // same things one directory further from the code.
        expect(
          snippets.length,
          greaterThanOrEqualTo(230),
          reason: 'far fewer snippets than the documentation carries',
        );

        final out = Directory(_outDir);
        if (out.existsSync()) out.deleteSync(recursive: true);
        out.createSync(recursive: true);
        try {
          final files = <String, _Snippet>{};
          for (var i = 0; i < snippets.length; i++) {
            final name = '$_outDir/snippet_${i + 1}.dart';
            File(name).writeAsStringSync(snippets[i].code);
            files[File(name).uri.pathSegments.last] = snippets[i];
          }

          // One analyzer run for all of them: one per snippet spent most of a
          // minute starting the analyzer over and over.
          final result = await Process.run('dart', [
            'analyze',
            '--no-fatal-warnings',
            out.path,
          ], workingDirectory: Directory.current.path);

          final failures = <String>[];
          for (final line in '${result.stdout}'.split('\n')) {
            final m = RegExp(
              r'^\s*error\s+-\s+(snippet_\d+\.dart):(\d+):(\d+)\s+-\s+(.*)$',
            ).firstMatch(line);
            if (m == null) continue;
            final snippet = files[m.group(1)];
            failures.add('${snippet?.origin ?? m.group(1)}  ->  ${m.group(4)}');
          }

          if (failures.isNotEmpty) {
            // Kept, not cleaned up: the generated file is what you read to
            // see what the snippet was compiled as.
            fail(
              'A documentation snippet does not compile. '
              '${snippets.length} checked, $skipped marked no-compile.\n'
              'Sources are kept in $_outDir.\n'
              '${failures.join('\n')}',
            );
          }
          out.deleteSync(recursive: true);
        } catch (_) {
          rethrow;
        }
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );
  });
}
