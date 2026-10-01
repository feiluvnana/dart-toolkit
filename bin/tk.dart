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
final paths = Arg.by('paths', Path.new, 'Files to digest').many().required();
final pattern = Arg.text('pattern', 'A glob, relative to here').or('**/*');
final file = Arg.by('file', Path.new, 'A YAML, TOML, INI or JSON file').required();
final link = Arg.by('url', (raw) => raw.url, 'The URL to GET').required();
final dir = Arg.by('dir', Path.new, 'The directory to archive').required();
final archive = Arg.by('archive', Path.new, 'The archive to list').required();

final algo = Opt.among('algo', Hash.values, 'Digest algorithm').abbr('a').or(Hash.sha256);
final top = Opt.number('top', 'How many to show').abbr('n').or(10);
final query = Opt.text('query', r'A JSONPath, e.g. $.dependencies.*').abbr('q');
final asYaml = Opt.flag('yaml', 'Print the document as YAML').abbr('y');
final out = Opt.text('out', 'Write to this path instead of stdout').abbr('o');
final to = Opt.by('to', Path.new, 'Destination, e.g. out.zip or out.tar.gz').abbr('t').required();

Future<void> main(List<String> args) => Cli(
  description: 'Small jobs, from the toolkit',
  version: '0.0.6',
  commands: [
    CliCommand('hash', 'Digest files, one per line', values: [paths, algo], handler: hash),
    CliCommand('find', 'The biggest files a glob matches', values: [pattern, top], handler: find),
    CliCommand('read', 'Query a document', values: [file, query, asYaml], handler: read),
    CliCommand('fetch', 'GET a URL to stdout or --out', values: [link, out], handler: fetch),
    CliCommand('pack', 'Archive a directory as --to says', values: [dir, to], handler: pack),
    CliCommand('peek', 'List an archive without extracting it', values: [archive], handler: peek),
  ],
).run(args);

/// Every file in one call to the native library, which hashes them in parallel.
Future<void> hash(CliContext ctx) async {
  final digests = await ctx(paths).hash(ctx(algo));
  digests.forEach((path, digest) => print('$digest  $path'));
}

/// A glob, then the biggest matches as a table.
Future<void> find(CliContext ctx) async {
  final glob = ctx(pattern);
  Console.debug('matching $glob under ${Path.current}');

  final files = await Path.current.glob(glob).toList();
  final sized = Table.rows(
    await files.parallelize((f) async => {'bytes': await f.size(), 'file': f.relativeTo(Path.current)}).rights,
  );

  if (sized.isEmpty) return Console.warn('nothing matched $glob');
  sized.orderBy('bytes', descending: true).take(ctx(top)).show();
  Console.ok('${sized.length} files, ${sized.numbers('bytes').sum} bytes');
}

/// Any of the four document formats, queried with one language.
Future<void> read(CliContext ctx) async {
  final doc = await JsonDocument.read(ctx(file));
  if (ctx(query) case final expression?) {
    return doc.$(expression).forEach(print);
  }
  print(ctx(asYaml) ? doc.toYaml() : '$doc');
}

/// To stdout, or to a file with progress.
Future<void> fetch(CliContext ctx) async {
  final url = ctx(link);

  await Http.scope(timeout: 30.s, () async {
    if (ctx(out) case final path?) {
      await path.path.download(url, overwrite: true).show(slots: 1, message: 'Fetching', done: 'Fetched');
      Console.ok('$path is ${await path.path.size()} bytes');
      return;
    }
    Io.out.write(await url.get().text);
  });
}

Future<void> pack(CliContext ctx) async {
  final source = ctx(dir);
  final target = ctx(to);

  await Console.spin(
    'Packing $source into ${target.name}…',
    () => source.archiveTo(target),
    done: 'Packed ${target.name}',
  );
  Console.ok('${target.name} is ${await target.size()} bytes from ${await source.size()} bytes');
}

Future<void> peek(CliContext ctx) async {
  final files = (await ctx(archive).archiveEntries()).where((e) => !e.isDir).toList();

  Table.rows(
    files.map((e) => {'size': e.size, 'packed': e.compressedSize, 'name': e.name}),
  ).orderBy('size', descending: true).take(20).show();
  Console.ok('${files.length} files, ${files.sequence.sumBy((e) => e.size)} bytes uncompressed');
}
