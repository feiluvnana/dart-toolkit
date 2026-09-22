import 'package:dart_toolkit/dart_toolkit.dart';

/// Reading the configuration a project actually has. YAML, TOML, INI and JSON all decode to
/// the same `JsonDocument`, so one query language and one `to<T>()` serve every one of them.
Future<void> main() async {
  Console.rule('This package, read from its own pubspec');

  final pubspec = (await 'pubspec.yaml'.path.readText()).yaml;
  Console.info('name     ${pubspec['name'].to<String>()}');
  Console.info('version  ${pubspec['version'].to<String>()}');
  Console.info('sdk      ${pubspec['environment']['sdk'].to<String>()}');

  // `$` is JSONPath. `..` descends, `*` takes every value at that level.
  Console.info('runtime deps  ${pubspec.$(r'$.dependencies.*').length}');
  Console.info('dev deps      ${pubspec.$(r'$.dev_dependencies.*').length}');
  Console.info('topics        ${pubspec.$(r'$.topics[*]').map((t) => t.to<String>()).join(', ')}');

  Console.rule('The same shape, whatever the format');

  const toml = '''
[server]
host = "0.0.0.0"
port = 8080
tags = ["edge", "eu-west"]

[server.tls]
enabled = true
''';

  const ini = '''
; a deploy profile
[staging]
url = https://staging.example.com
port = 9090
workers = 4
verbose = yes
''';

  const json = '{"server": {"host": "127.0.0.1", "port": 3000}}';

  // Every one of these is a JsonDocument: same indexing, same `$`, same `to<T>()`.
  for (final (label, doc) in [('toml', toml.toml), ('ini', ini.ini), ('json', json.json)]) {
    final port = doc.$(r'$..port').firstOrNull?.to<int>();
    Console.info('$label  port=${port ?? '—'}  keys=${doc.map.keys.join(', ')}');
  }

  // Values are typed on the way out, and text converts when it can: `port = 8080` in TOML is
  // already an int, `workers = 4` in INI too, and a quoted "8080" would still read as one.
  final server = toml.toml['server'];
  Console.ok('tls enabled: ${server['tls']['enabled'].to<bool>()}');
  Console.ok('tags: ${server['tags'].list.map((t) => t.to<String>()).join(' + ')}');
  Console.ok('a missing key is the null document, not a crash: ${server['nope']['deeper'].isNull}');

  Console.rule('Out again, as YAML');

  Io.out.writeln(toml.toml.toYaml());

  Console.rule('A JSON array of objects is a Table');

  const payload = '''
[
  {"id": 3, "name": "cache",  "region": "eu-west", "rps": 1840},
  {"id": 1, "name": "api",    "region": "eu-west", "rps": 920},
  {"id": 2, "name": "worker", "region": "us-east", "rps": 140}
]
''';

  payload.json.table.orderBy('region').thenBy('rps', descending: true).select(['name', 'region', 'rps']).show();

  final busiest = payload.json.table.groupBy('region').sum('rps', as: 'total').orderBy('total', descending: true);
  Console.ok('busiest region: ${busiest.rows.first.text('region')} at ${busiest.rows.first.number('total')} rps');

  Console.rule('XML, when the answer is a feed');

  const feed = '''
<rss><channel>
  <item><title>Second release</title><pubDate>Tue, 16 Sep 2025</pubDate></item>
  <item><title>First release</title><pubDate>Mon, 01 Sep 2025</pubDate></item>
</channel></rss>
''';

  // XML answers to XPath, so `$` here is a path rather than a key.
  final items = feed.xml.$x('//item');
  Console.info('items: ${items.length}');
  Console.info('first title: ${items.$('title').text}');
  Console.info('all titles: ${feed.xml.$x('//item/title').texts.join(' | ')}');
}
