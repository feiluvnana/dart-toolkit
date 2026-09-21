import 'package:dart_toolkit/dart_toolkit.dart';

/// `tk` — the toolkit as a tool. Every command is a few lines over the library, which makes
/// this the composition test: if a command needs a helper the package does not have, that is
/// the package's problem, not the command's.
///
///   dart run dart_toolkit:tk hash pubspec.yaml README.md --algo blake3
///   dart run dart_toolkit:tk find 'lib/**/*.dart' --top 5
///   dart run dart_toolkit:tk read pubspec.yaml --query '$.dependencies.*'
///   dart run dart_toolkit:tk read pubspec.yaml --yaml
///   dart run dart_toolkit:tk fetch https://example.com
///   dart run dart_toolkit:tk pack lib --to /tmp/lib.zip
///   dart run dart_toolkit:tk peek /tmp/lib.zip
Future<void> main(List<String> args) async {
  final tk = Cli(name: 'tk', description: 'Small jobs, from the toolkit', version: '0.0.1')
    ..flag('verbose', abbr: 'v', description: 'Show debug logging')
    ..command(
      'hash',
      description: 'Digest files, one per line',
      build: (c) => c
        ..choice('algo', [for (final h in Hash.values) h.name], abbr: 'a', defaultTo: 'sha256')
        ..action(hash),
    )
    ..command(
      'find',
      description: 'Match a glob and report the biggest hits',
      build: (c) => c
        ..number('top', abbr: 'n', defaultTo: 10, description: 'How many to show')
        ..action(find),
    )
    ..command(
      'read',
      description: 'Parse YAML, TOML, INI or JSON and query it',
      build: (c) => c
        ..option('query', abbr: 'q', description: r'A JSONPath, e.g. $.dependencies.*')
        ..flag('yaml', abbr: 'y', description: 'Print the document as YAML')
        ..action(read),
    )
    ..command(
      'fetch',
      description: 'GET a URL to stdout, or to a file with --out',
      build: (c) => c
        ..option('out', abbr: 'o', description: 'Write to this path instead of stdout')
        ..action(fetch),
    )
    ..command(
      'pack',
      description: 'Archive a directory; the format comes from --to',
      build: (c) => c
        ..option('to', abbr: 't', required: true, description: 'Destination, e.g. out.zip or out.tar.gz')
        ..action(pack),
    )
    ..command('peek', description: 'List an archive without extracting it', handler: peek);

  await tk.run(args);
}

/// One path per positional argument, hashed in parallel, reported in input order.
Future<void> hash(CliContext ctx) async {
  _verbose(ctx);
  if (ctx.rest.isEmpty) await die('hash needs at least one path');
  final algorithm = Hash.values.firstWhere((h) => h.name == ctx.option('algo'));

  final digested = await ctx.rest.parallelize(
    (path) async => (path: path, digest: await path.path.hash(algorithm)),
    concurrency: 4,
    cancelToken: ctx.cancel,
  );

  for (final row in digested.rights) {
    Io.out.writeln('${row.digest}  ${row.path}');
  }
  for (final failure in digested.lefts) {
    Logger.error('$failure');
  }
}

/// A glob, then the biggest matches as a table.
Future<void> find(CliContext ctx) async {
  _verbose(ctx);
  final pattern = ctx.rest.firstOrNull ?? '**/*';
  Logger.debug('matching $pattern under ${Path.current}');

  final matches = await Path.current.glob(pattern).toList();
  final sized = await matches.parallelize((f) async => (file: f.relativeTo(Path.current), bytes: await f.size()));

  if (sized.rights.isEmpty) {
    Logger.warn('nothing matched $pattern');
    return;
  }
  Table.records(
    sized.rights.sequence.sortedBy((r) => r.bytes, descending: true).take(ctx.number('top')),
    (r) => {'bytes': r.bytes, 'file': r.file},
  ).show();
  Logger.ok('${sized.rights.length} matches, ${sized.rights.sequence.sumBy((r) => r.bytes)} bytes');
}

/// Any of the four document formats, queried with one language.
Future<void> read(CliContext ctx) async {
  _verbose(ctx);
  final file = (ctx.rest.firstOrNull ?? await die('read needs a file')).path;
  final text = await file.readText();

  // The parser is chosen here rather than by the library: a file's extension is a guess, and
  // a wrong guess should be the caller's to make.
  final doc = switch (file.ext.toLowerCase()) {
    'yaml' || 'yml' => text.yaml,
    'toml' => text.toml,
    'ini' || 'cfg' || 'conf' => text.ini,
    'json' => text.json,
    final other => throw UsageException('cannot read ".$other"; try yaml, toml, ini or json'),
  };

  if (ctx.optionOrNull('query') case final query?) {
    final hits = doc.$(query);
    Logger.debug('${hits.length} hits for $query');
    for (final hit in hits) {
      Io.out.writeln(hit);
    }
    return;
  }
  Io.out.writeln(ctx.flag('yaml') ? doc.toYaml() : '$doc');
}

/// To stdout, or to a file with progress.
Future<void> fetch(CliContext ctx) async {
  _verbose(ctx);
  final url = (ctx.rest.firstOrNull ?? await die('fetch needs a URL')).url;

  await Http.session(timeout: 30.s, () async {
    if (ctx.optionOrNull('out') case final out?) {
      // `download` reports one file; the batch form is what `show()` renders, so a single
      // download goes through a one-entry map.
      final last = await {
        url: out.path,
      }.downloadAll(overwrite: true, cancelToken: ctx.cancel).show(slots: 1, message: 'Fetching', done: 'Fetched');
      if (last?.current case DownloadFailed(:final error)) await die('$error');
      Logger.ok('$out is ${await out.path.size()} bytes');
      return;
    }
    final res = await url.get();
    if (!res.isOk) await die('${res.statusCode} ${res.reasonPhrase ?? ''}'.trim());
    Io.out.write(res.text);
  });
}

Future<void> pack(CliContext ctx) async {
  _verbose(ctx);
  final source = (ctx.rest.firstOrNull ?? await die('pack needs a directory')).path;
  final to = ctx.option('to').path;

  await Console.spin('Packing $source into ${to.name}…', () => source.archiveTo(to), done: 'Packed ${to.name}');
  Logger.ok('${to.name} is ${await to.size()} bytes from ${await source.size()} bytes');
}

Future<void> peek(CliContext ctx) async {
  _verbose(ctx);
  final archive = (ctx.rest.firstOrNull ?? await die('peek needs an archive')).path;
  final entries = await archive.archiveEntries();

  Table.records(
    entries.where((e) => !e.isDir),
    (e) => {'size': e.size, 'packed': e.compressedSize, 'name': e.name},
  ).orderBy('size', descending: true).take(20).show();

  final files = entries.where((e) => !e.isDir);
  Logger.ok('${files.length} files, ${files.sequence.sumBy((e) => e.size)} bytes uncompressed');
}

void _verbose(CliContext ctx) {
  if (ctx.flag('verbose')) Logger.level = LogLevel.debug;
}
