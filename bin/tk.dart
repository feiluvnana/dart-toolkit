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
library;

import 'package:dart_toolkit/dart_toolkit.dart';

/// The options and arguments, declared once as values: the name is written here and nowhere
/// else, and `ctx(top)` comes back an `int` because `top` says so.
final paths = Arg.rest('paths', description: 'Files to digest').required();
final pattern = Arg.text('pattern', description: 'A glob, relative to here').or('**/*');
final file = Arg.text('file', description: 'A YAML, TOML, INI or JSON file').required();
final link = Arg.by('url', (raw) => raw.url, description: 'The URL to GET').required();
final dir = Arg.text('dir', description: 'The directory to archive').required();
final archive = Arg.text('archive', description: 'The archive to list').required();

final verbose = Opt.flag('verbose', abbr: 'v', description: 'Show debug logging');
final algo = Opt.among('algo', Hash.values, abbr: 'a', description: 'Digest algorithm').or(Hash.sha256);
final top = Opt.number('top', abbr: 'n', description: 'How many to show').or(10);
final query = Opt.text('query', abbr: 'q', description: r'A JSONPath, e.g. $.dependencies.*');
final asYaml = Opt.flag('yaml', abbr: 'y', description: 'Print the document as YAML');
final out = Opt.text('out', abbr: 'o', description: 'Write to this path instead of stdout');
final to = Opt.text('to', abbr: 't', description: 'Destination, e.g. out.zip or out.tar.gz').required();

Future<void> main(List<String> args) => Cli(
  name: 'tk',
  description: 'Small jobs, from the toolkit',
  version: '0.0.2',
  options: [verbose],
  commands: [
    CliCommand('hash', description: 'Digest files, one per line', args: [paths], options: [algo], handler: _cmd(hash)),
    CliCommand(
      'find',
      description: 'Match a glob and report the biggest hits',
      args: [pattern],
      options: [top],
      handler: _cmd(find),
    ),
    CliCommand(
      'read',
      description: 'Parse YAML, TOML, INI or JSON and query it',
      args: [file],
      options: [query, asYaml],
      handler: _cmd(read),
    ),
    CliCommand(
      'fetch',
      description: 'GET a URL to stdout, or to a file with --out',
      args: [link],
      options: [out],
      handler: _cmd(fetch),
    ),
    CliCommand(
      'pack',
      description: 'Archive a directory; the format comes from --to',
      args: [dir],
      options: [to],
      handler: _cmd(pack),
    ),
    CliCommand('peek', description: 'List an archive without extracting it', args: [archive], handler: _cmd(peek)),
  ],
).run(args);

/// The root's `--verbose` reads the same way for every command, so it is applied here once
/// rather than as the first line of six handlers.
CommandHandler _cmd(CommandHandler run) => (ctx) {
  if (ctx(verbose)) Console.level = LogLevel.debug;
  return run(ctx);
};

/// One path per positional argument, hashed in parallel, reported in input order.
Future<void> hash(CliContext ctx) async {
  final algorithm = ctx(algo);

  final digested = await ctx(
    paths,
  ).parallelize((path) async => (path: path, digest: await path.path.hash(algorithm)), concurrency: 4);

  for (final row in digested.rights) {
    Io.out.writeln('${row.digest}  ${row.path}');
  }
  for (final failure in digested.lefts) {
    Console.error('$failure');
  }
}

/// A glob, then the biggest matches as a table.
Future<void> find(CliContext ctx) async {
  final glob = ctx(pattern);
  Console.debug('matching $glob under ${Path.current}');

  final matches = await Path.current.glob(glob).toList();
  final sized = (await matches.parallelize(
    (f) async => (file: f.relativeTo(Path.current), bytes: await f.size()),
  )).rights;

  if (sized.isEmpty) {
    Console.warn('nothing matched $glob');
    return;
  }
  Table.rows(
    sized.sequence
        .sortedBy((r) => r.bytes, descending: true)
        .take(ctx(top))
        .map((r) => {'bytes': r.bytes, 'file': r.file}),
  ).show();
  Console.ok('${sized.length} matches, ${sized.sequence.sumBy((r) => r.bytes)} bytes');
}

/// Any of the four document formats, queried with one language.
Future<void> read(CliContext ctx) async {
  final source = ctx(file).path;
  final text = await source.readText();

  // The parser is chosen here rather than by the library: a file's extension is a guess, and
  // a wrong guess should be the caller's to make.
  final doc = switch (source.ext.toLowerCase()) {
    'yaml' || 'yml' => text.yaml,
    'toml' => text.toml,
    'ini' || 'cfg' || 'conf' => text.ini,
    'json' => text.json,
    final other => throw UsageException('cannot read ".$other"; try yaml, toml, ini or json'),
  };

  if (ctx(query) case final expression?) {
    final hits = doc.$(expression);
    Console.debug('${hits.length} hits for $expression');
    for (final hit in hits) {
      Io.out.writeln(hit);
    }
    return;
  }
  Io.out.writeln(ctx(asYaml) ? doc.toYaml() : '$doc');
}

/// To stdout, or to a file with progress.
Future<void> fetch(CliContext ctx) async {
  final url = ctx(link);

  await Http.scope(timeout: 30.s, () async {
    if (ctx(out) case final path?) {
      final last = await path.path.download(url, overwrite: true).show(slots: 1, message: 'Fetching', done: 'Fetched');
      if (last?.current case DownloadFailed(:final error)) await Lifecycle.exit('$error');
      Console.ok('$path is ${await path.path.size()} bytes');
      return;
    }
    final res = await url.get();
    if (!res.isOk) await Lifecycle.exit('${res.statusCode} ${res.reasonPhrase ?? ''}'.trim());
    Io.out.write(res.text);
  });
}

Future<void> pack(CliContext ctx) async {
  final source = ctx(dir).path;
  final target = ctx(to).path;

  await Console.spin(
    'Packing $source into ${target.name}…',
    () => source.archiveTo(target),
    done: 'Packed ${target.name}',
  );
  Console.ok('${target.name} is ${await target.size()} bytes from ${await source.size()} bytes');
}

Future<void> peek(CliContext ctx) async {
  final files = (await ctx(archive).path.archiveEntries()).where((e) => !e.isDir).toList();

  Table.rows(
    files.map((e) => {'size': e.size, 'packed': e.compressedSize, 'name': e.name}),
  ).orderBy('size', descending: true).take(20).show();
  Console.ok('${files.length} files, ${files.sequence.sumBy((e) => e.size)} bytes uncompressed');
}
