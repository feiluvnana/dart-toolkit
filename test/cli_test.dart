import 'dart:io';

import 'package:dart_toolkit/cli.dart';
import 'package:test/test.dart';

void main() {
  group('options', () {
    test('typed Option with default, reads and coerces', () async {
      final top = Option<int>('top', 'N.', short: 'n', defaultsTo: 10);
      int? seen;
      final cli = Command('app', 'X.',
          params: [top], handler: (ctx) => seen = ctx(top));
      expect(await cli.run([]), 0);
      expect(seen, 10);
      expect(await cli.run(['--top', '3']), 0);
      expect(seen, 3);
      expect(await cli.run(['-n4']), 0);
      expect(seen, 4);
      expect(await cli.run(['--top', 'soon']), 64);
    });

    test('T is inferred from defaultsTo: and parse:', () async {
      final port = Option('port', 'Port.', short: 'p', defaultsTo: 8080);
      final since = Option('since', 'Start date.',
          parse: DateTime.parse, defaultsTo: DateTime(2020));
      // Static proof: no explicit type arguments above, yet these assign.
      Option<int> checkPort = port;
      Option<DateTime> checkSince = since;
      int? seenPort;
      DateTime? seenSince;
      final cli = Command('app', 'X.',
          params: [checkPort, checkSince],
          handler: (ctx) {
            seenPort = ctx(port);
            seenSince = ctx(since);
          });
      expect(await cli.run([]), 0);
      expect(seenPort, 8080);
      expect(seenSince, DateTime(2020));
      expect(await cli.run(['--port', '1', '--since', '2026-10-08']), 0);
      expect(seenPort, 1);
      expect(seenSince, DateTime(2026, 10, 8));
    });

    test('V19: non-nullable reads as T, nullable as T?', () async {
      final out = Option<String>('out', 'O.', short: 'o', defaultsTo: 'd');
      final maybe = Option<String?>('maybe', 'M.');
      String? s;
      String? n;
      final cli = Command('app', 'X.',
          params: [out, maybe],
          handler: (ctx) {
            s = ctx(out);
            n = ctx(maybe);
          });
      expect(await cli.run([]), 0);
      expect(s, 'd');
      expect(n, isNull);
      expect(await cli.run(['--maybe', 'x']), 0);
      expect(n, 'x');
    });

    test('non-nullable without defaultsTo/required is an ArgumentError', () {
      expect(() => Option<String>('x', 'X.'), throwsArgumentError);
      expect(() => Option<int?>('x', 'X.'), returnsNormally);
      expect(() => Argument<String>('x', 'X.'), throwsArgumentError);
      expect(() => Argument<String?>('x', 'X.'), returnsNormally);
    });

    test('C13: yes/no is always a Flag', () {
      expect(() => Option<bool>('x', 'X.', defaultsTo: true), throwsArgumentError);
      expect(() => MultiOption<bool>('x', 'X.'), throwsArgumentError);
      expect(() => Argument<bool>('x', 'X.'), throwsArgumentError);
    });

    test('Flag defaultsTo:true reads --no-name', () async {
      final color = Flag('color', 'C.', defaultsTo: true);
      var seen = -1;
      final cli = Command('app', 'X.',
          params: [color],
          handler: (ctx) => seen = ctx(color) ? 1 : 0);
      expect(await cli.run(['--no-color']), 0);
      expect(seen, 0);
      expect(await cli.run([]), 0);
      expect(seen, 1);
    });

    test('required Option missing is 64', () async {
      final req = Option<String>('token', 'T.', required: true);
      final cli = Command('app', 'X.', params: [req], handler: (_) {});
      expect(await cli.run([]), 64);
      expect(await cli.run(['--token', 'x']), 0);
    });

    test('C3: a required parent Option is checked when dispatching', () async {
      final token = Option<String>('token', 'T.', required: true);
      final cli = Command('app', 'X.', params: [token], subcommands: [
        Command('go', 'Go.', handler: (_) {}),
      ]);
      expect(await cli.run(['go']), 64);
      expect(await cli.run(['--token', 'x', 'go']), 0);
    });

    test('C1/C2: parent MultiOption merges typed, before and after', () async {
      final tag = MultiOption<String>('tag', 'A tag.', short: 't');
      List<String> tags = const [];
      final cli = Command('app', 'X.', params: [tag], subcommands: [
        Command('go', 'Go.', handler: (ctx) => tags = ctx(tag)),
      ]);
      expect(await cli.run(['--tag', 'a', 'go', '--tag', 'b']), 0);
      expect(tags, ['a', 'b']);
    });

    test('C4: MultiOption with parse: reads as List<T>', () async {
      final col = MultiOption<Color>('col', 'C.', parse: Color.parse);
      List<Color> seen = const [];
      final cli = Command('app', 'X.',
          params: [col], handler: (ctx) => seen = ctx(col));
      expect(await cli.run(['--col', 'red', '--col', '#00ff00']), 0);
      expect(seen, [Color.red, const Color(0x00ff00)]);
      expect(await cli.run([]), 0);
      expect(seen, isEmpty);
    });

    test('C5: a short h keeps --help', () async {
      final h = Option<String>('host', 'H.', short: 'h', defaultsTo: 'x');
      final cli = Command('app', 'X.', params: [h], handler: (_) {});
      expect(await cli.run(['--help']), 0);
      expect(await cli.run(['-h', 'y']), 0);
      expect(() => Flag('help', 'H.'), throwsArgumentError);
      expect(() => Option<String>('help', 'H.', defaultsTo: 'x'), throwsArgumentError);
    });

    test('grouped shorts, attached params, -- ends options', () async {
      final v = Flag('verbose', 'V.', short: 'v');
      final n = Option<int>('n', 'N.', short: 'n', defaultsTo: 0);
      var vv = false;
      var nn = -1;
      List<String> tail = const [];
      final cli = Command('app', 'X.',
          params: [v, n],
          handler: (ctx) {
            vv = ctx(v);
            nn = ctx(n);
            tail = ctx.extraArgs();
          });
      expect(await cli.run(['-vn3']), 0);
      expect((vv, nn), (true, 3));
      expect(await cli.run(['--', '-v']), 0);
      expect(tail, ['-v']);
    });

    test('-5 stays positional when no short answers to it', () async {
      final q = Argument<String?>('q', 'Query.');
      String? seen;
      List<String> tail = const [];
      final cli = Command('app', 'X.',
          params: [q],
          handler: (ctx) {
            seen = ctx(q);
            tail = ctx.extraArgs();
          });
      expect(await cli.run(['-5']), 0);
      expect(seen, '-5');
      expect(tail, isEmpty);
    });

    test('Duration, DateTime and Uri params; negative durations', () async {
      final wait = Option<Duration>('wait', 'W.', defaultsTo: Duration.zero);
      final when = Option<DateTime?>('when', 'W.');
      final uri = Option<Uri?>('uri', 'U.');
      Duration? d;
      DateTime? dt;
      Uri? u;
      final cli = Command('app', 'X.',
          params: [wait, when, uri],
          handler: (ctx) {
            d = ctx(wait);
            dt = ctx(when);
            u = ctx(uri);
          });
      expect(await cli.run(['--wait', '1h30m', '--when', '2026-10-08']), 0);
      expect(d, const Duration(hours: 1, minutes: 30));
      expect(dt, DateTime(2026, 10, 8));
      expect(await cli.run(['--wait', '-5s']), 0);
      expect(d, const Duration(seconds: -5));
      expect(
          await cli.run(
              ['--uri', 'https://example.com/x', '--wait', '90']),
          0);
      expect(u, Uri.parse('https://example.com/x'));
      expect(d, const Duration(seconds: 90));
      expect(await cli.run(['--wait', 'soon']), 64);
      expect(await cli.run(['--uri', 'notaurl']), 64);
    });

    test('suggestions name options, not Args; -vh helps', () async {
      final verbose = Flag('verbose', 'V.', short: 'v');
      final url = Option<String>('url', 'U.', defaultsTo: '');
      final q = Argument<String?>('q', 'Q.');
      final cli = Command('app', 'X.',
          params: [verbose, url, q], handler: (_) {});
      expect(await cli.run(['--urlx', 'y']), 64);
      expect(await cli.run(['-vh']), 0);
    });

    test('the hint names the deepest command reached', () async {
      final cli = Command('app', 'X.', subcommands: [
        Command('remote', 'R.', subcommands: [
          Command('add', 'A.', handler: (_) {}),
        ]),
      ]);
      expect(await cli.run(['remote', '--bogus']), 64);
    });
  });

  group('positionals', () {
    test('Args bind in order; rest is the tail', () async {
      final src = Argument<String>('src', 'S.', required: true);
      final dst = Argument<String?>('dst', 'D.');
      String? s;
      String? d;
      List<String> tail = const [];
      final cli = Command('cp', 'Copy.', params: [src, dst], handler: (ctx) {
        s = ctx(src);
        d = ctx(dst);
        tail = ctx.extraArgs();
      });
      expect(await cli.run(['a', 'b']), 0);
      expect(s, 'a');
      expect(d, 'b');
      expect(tail, isEmpty);
      expect(await cli.run(['a']), 0);
      expect(s, 'a');
      expect(d, isNull);
      expect(await cli.run([]), 64);
      expect(await cli.run(['a', 'b', 'c']), 64);
    });

    test('a query of help stays positional when Args exist', () async {
      final q = Argument<String>('q', 'Query.', required: true);
      String? seen;
      final cli = Command('app', 'X.',
          params: [q], handler: (ctx) => seen = ctx(q));
      expect(await cli.run(['help']), 0);
      expect(seen, 'help');
    });
  });

  group('subcommands', () {
    test('dispatch by name and alias; ancestor options work after', () async {
      final tag = MultiOption<String>('tag', 'A tag.', short: 't');
      final file = Argument<String>('file', 'F.', required: true);
      var built = '';
      List<String> tags = const [];
      final cli = Command('tk', 'Tool.', params: [tag], subcommands: [
        Command('build', 'Builds.', aliases: ['b'], params: [file],
            handler: (ctx) {
          built = ctx(file);
          tags = ctx(tag);
        }),
      ]);
      expect(await cli.run(['build', '--tag', 'a', 'f1']), 0);
      expect(built, 'f1');
      expect(tags, ['a']);
      expect(await cli.run(['b', 'f1']), 0);
      expect(built, 'f1');
    });

    test('C6: help works at depth; unknown help names suggest', () async {
      final cli = Command('tk', 'Tool.', subcommands: [
        Command('remote', 'R.', subcommands: [
          Command('add', 'A.', handler: (_) {}),
        ]),
      ]);
      expect(await cli.run(['help', 'remote', 'add']), 0);
      expect(await cli.run(['remote', 'help', 'add']), 0);
      expect(await cli.run(['help', 'rmove']), 64);
    });

    test('--help is 0, unknown command is 64, UsageException is 64',
        () async {
      final cli = Command('tk', 'Tool.', subcommands: [
        Command('build', 'Builds.', handler: (_) {}),
      ]);
      expect(await cli.run(['--help']), 0);
      expect(await cli.run(['help', 'build']), 0);
      expect(await cli.run(['rmove']), 64);
      final bad = Command('app', 'X.',
          handler: (_) => throw const UsageException('nope'));
      expect(await bad.run([]), 64);
    });

    test('C10: handler Errors propagate with their stack', () async {
      final cli = Command('app', 'X.',
          handler: (_) => throw StateError('bug'));
      var threw = false;
      try {
        await cli.run([]);
      } on StateError {
        threw = true;
      }
      expect(threw, isTrue);
      final exc = Command('app', 'X.',
          handler: (_) => throw FormatException('bad input'));
      expect(await exc.run([]), 1);
    });

    test('C14: children cannot redeclare ancestor options', () {
      final tag = Option<String>('tag', 'T.', defaultsTo: '');
      expect(
        () => Command('app', 'X.', params: [tag], subcommands: [
          Command('go', 'G.', params: [Option<String>('tag', 'Other.')]),
        ]),
        throwsArgumentError,
      );
      final v = Flag('verbose', 'V.', short: 'v');
      expect(
        () => Command('app', 'X.', params: [v], subcommands: [
          Command('go', 'G.', params: [Flag('other', 'O.', short: 'v')]),
        ]),
        throwsArgumentError,
      );
      // Sharing the identical Def object is fine.
      expect(
        () => Command('app', 'X.', params: [tag], subcommands: [
          Command('go', 'G.', params: [tag], handler: (_) {}),
        ]),
        returnsNormally,
      );
      expect(() => Command('bad name', 'X.'), throwsArgumentError);
    });

    test('usage lists -h, --help and reads back', () async {
      final top = Option<int>('top', 'N.', defaultsTo: 1);
      String? usage;
      final cli = Command('app', 'X.',
          params: [top], handler: (ctx) => usage = ctx.usage());
      expect(await cli.run([]), 0);
      expect(usage, contains('-h, --help'));
      expect(usage, contains('Usage: app'));
    });
  });

  group('arguments and subcommands', () {
    test('M3: a command cannot declare both', () {
      expect(
          () => Command('app', 'X.',
              params: [Argument<String>('file', 'F.')],
              subcommands: [Command('sub', 'S.')]),
          throwsArgumentError);
    });
  });

  group('parse: errors', () {
    test('M5: an Error from parse: propagates, an Exception is usage', () async {
      final bug = Option<int>('n', 'N.', defaultsTo: 0, parse: (_) => throw RangeError('bug'));
      expect(Command('app', 'X.', params: [bug]).run(['--n', '1']),
          throwsA(isA<RangeError>()));
      final bad = Option<int>('n', 'N.', defaultsTo: 0, parse: (_) => throw Exception('no'));
      expect(await Command('app', 'X.', params: [bad]).run(['--n', '1']), 64);
    });
  });

  group('suggestions', () {
    test('L1: short options suggest only the case-swapped letter', () async {
      final dir = Directory.systemTemp.createTempSync('cli_l1');
      addTearDown(() => dir.deleteSync(recursive: true));
      final script = File('${dir.path}/m.dart')..writeAsStringSync('''
import 'dart:io';
import 'package:dart_toolkit/cli.dart';
Future<void> main(List<String> a) async {
  final v = Flag('verbose', 'V.', short: 'v');
  exitCode = await Command('app', 'X.', params: [v], handler: (_) {}).run(a);
}
''');
      Future<String> err(String arg) async {
        final r = await Process.run(Platform.resolvedExecutable, [
          '--packages=${Directory.current.path}/.dart_tool/package_config.json',
          script.path,
          arg,
        ]);
        expect(r.exitCode, 64);
        return r.stderr as String;
      }

      expect(await err('-x'), isNot(contains('Did you mean')));
      expect(await err('-V'), contains('Did you mean "-v"'));
    });
  });

  group('schema', () {
    test('ctx on undeclared definition is StateError', () async {
      final top = Option<int>('top', 'N.', defaultsTo: 1);
      final other = Option<int?>('other', 'O.');
      var stateErr = false;
      final cli = Command('app', 'X.',
          params: [top],
          handler: (ctx) {
            try {
              ctx(other);
            } on StateError {
              stateErr = true;
            }
          });
      await cli.run([]);
      expect(stateErr, isTrue);
    });

    test('schema validation is ArgumentError', () {
      expect(() => Flag('x', 'X.', short: 'xy'), throwsArgumentError);
      expect(
          () => Option<String>('x', 'X.', required: true, defaultsTo: 'd'),
          throwsArgumentError);
      expect(
          () => Command('c', 'C.', params: [
                Option<String>('x', 'X.', defaultsTo: ''),
                Option<String>('x', 'Y.', defaultsTo: ''),
              ]),
          throwsArgumentError);
      expect(
          () => Command('c', 'C.',
              params: [
                    Argument<String?>('id', 'I.'),
                    Argument<String>('req', 'R.', required: true),
                  ]),
          throwsArgumentError);
    });
  });
}

/// A custom value type proving that Multis with parse read as typed lists.
class Color {
  const Color(this.rgb);

  final int rgb;

  static const red = Color(0xff0000);

  static Color parse(String raw) {
    if (raw == 'red') return red;
    final hex = raw.startsWith('#') ? raw.substring(1) : raw;
    final v = int.tryParse(hex, radix: 16);
    if (v == null) throw FormatException('not a color: $raw');
    return Color(v);
  }

  @override
  bool operator ==(Object other) => other is Color && other.rgb == rgb;

  @override
  int get hashCode => rgb;

  @override
  String toString() => 'Color($rgb)';
}
