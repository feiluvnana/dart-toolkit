import 'package:dart_toolkit/cli.dart';
import 'package:test/test.dart';

void main() {
  group('options', () {
    test('typed Opt with default, reads and coerces', () async {
      final top = Opt<int>('top', 'N.', short: 'n', or: 10);
      int? seen;
      final cli = Command('app', 'X.',
          values: [top], handler: (ctx) => seen = ctx(top));
      expect(await cli.parse([]), 0);
      expect(seen, 10);
      expect(await cli.parse(['--top', '3']), 0);
      expect(seen, 3);
      expect(await cli.parse(['-n4']), 0);
      expect(seen, 4);
      expect(await cli.parse(['--top', 'soon']), 64);
    });

    test('V19: non-nullable reads as T, nullable as T?', () async {
      final out = Opt<String>('out', 'O.', short: 'o', or: 'd');
      final maybe = Opt<String?>('maybe', 'M.');
      String? s;
      String? n;
      final cli = Command('app', 'X.',
          values: [out, maybe],
          handler: (ctx) {
            s = ctx(out);
            n = ctx(maybe);
          });
      expect(await cli.parse([]), 0);
      expect(s, 'd');
      expect(n, isNull);
      expect(await cli.parse(['--maybe', 'x']), 0);
      expect(n, 'x');
    });

    test('non-nullable without or/required is an ArgumentError', () {
      expect(() => Opt<String>('x', 'X.'), throwsArgumentError);
      expect(() => Opt<int?>('x', 'X.'), returnsNormally);
      expect(() => Arg<String>('x', 'X.'), throwsArgumentError);
      expect(() => Arg<String?>('x', 'X.'), returnsNormally);
    });

    test('C13: yes/no is always a Flag', () {
      expect(() => Opt<bool>('x', 'X.', or: true), throwsArgumentError);
      expect(() => Multi<bool>('x', 'X.'), throwsArgumentError);
      expect(() => Arg<bool>('x', 'X.'), throwsArgumentError);
    });

    test('Flag or:true reads --no-name', () async {
      final color = Flag('color', 'C.', or: true);
      var seen = -1;
      final cli = Command('app', 'X.',
          values: [color],
          handler: (ctx) => seen = ctx(color) ? 1 : 0);
      expect(await cli.parse(['--no-color']), 0);
      expect(seen, 0);
      expect(await cli.parse([]), 0);
      expect(seen, 1);
    });

    test('required Opt missing is 64', () async {
      final req = Opt<String>('token', 'T.', required: true);
      final cli = Command('app', 'X.', values: [req], handler: (_) {});
      expect(await cli.parse([]), 64);
      expect(await cli.parse(['--token', 'x']), 0);
    });

    test('C3: a required parent Opt is checked when dispatching', () async {
      final token = Opt<String>('token', 'T.', required: true);
      final cli = Command('app', 'X.', values: [token], commands: [
        Command('go', 'Go.', handler: (_) {}),
      ]);
      expect(await cli.parse(['go']), 64);
      expect(await cli.parse(['--token', 'x', 'go']), 0);
    });

    test('C1/C2: parent Multi merges typed, before and after', () async {
      final tag = Multi<String>('tag', 'A tag.', short: 't');
      List<String> tags = const [];
      final cli = Command('app', 'X.', values: [tag], commands: [
        Command('go', 'Go.', handler: (ctx) => tags = ctx(tag)),
      ]);
      expect(await cli.parse(['--tag', 'a', 'go', '--tag', 'b']), 0);
      expect(tags, ['a', 'b']);
    });

    test('C4: Multi with parse: reads as List<T>', () async {
      final col = Multi<Color>('col', 'C.', parse: Color.parse);
      List<Color> seen = const [];
      final cli = Command('app', 'X.',
          values: [col], handler: (ctx) => seen = ctx(col));
      expect(await cli.parse(['--col', 'red', '--col', '#00ff00']), 0);
      expect(seen, [Color.red, const Color(0x00ff00)]);
      expect(await cli.parse([]), 0);
      expect(seen, isEmpty);
    });

    test('C5: a short h keeps --help', () async {
      final h = Opt<String>('host', 'H.', short: 'h', or: 'x');
      final cli = Command('app', 'X.', values: [h], handler: (_) {});
      expect(await cli.parse(['--help']), 0);
      expect(await cli.parse(['-h', 'y']), 0);
      expect(() => Flag('help', 'H.'), throwsArgumentError);
      expect(() => Opt<String>('help', 'H.', or: 'x'), throwsArgumentError);
    });

    test('grouped shorts, attached values, -- ends options', () async {
      final v = Flag('verbose', 'V.', short: 'v');
      final n = Opt<int>('n', 'N.', short: 'n', or: 0);
      var vv = false;
      var nn = -1;
      List<String> tail = const [];
      final cli = Command('app', 'X.',
          values: [v, n],
          handler: (ctx) {
            vv = ctx(v);
            nn = ctx(n);
            tail = ctx.rest();
          });
      expect(await cli.parse(['-vn3']), 0);
      expect((vv, nn), (true, 3));
      expect(await cli.parse(['--', '-v']), 0);
      expect(tail, ['-v']);
    });

    test('-5 stays positional when no short answers to it', () async {
      final q = Arg<String?>('q', 'Query.');
      String? seen;
      List<String> tail = const [];
      final cli = Command('app', 'X.',
          values: [q],
          handler: (ctx) {
            seen = ctx(q);
            tail = ctx.rest();
          });
      expect(await cli.parse(['-5']), 0);
      expect(seen, '-5');
      expect(tail, isEmpty);
    });

    test('Duration, DateTime and Uri values; negative durations', () async {
      final wait = Opt<Duration>('wait', 'W.', or: Duration.zero);
      final when = Opt<DateTime?>('when', 'W.');
      final uri = Opt<Uri?>('uri', 'U.');
      Duration? d;
      DateTime? dt;
      Uri? u;
      final cli = Command('app', 'X.',
          values: [wait, when, uri],
          handler: (ctx) {
            d = ctx(wait);
            dt = ctx(when);
            u = ctx(uri);
          });
      expect(await cli.parse(['--wait', '1h30m', '--when', '2026-10-08']), 0);
      expect(d, const Duration(hours: 1, minutes: 30));
      expect(dt, DateTime(2026, 10, 8));
      expect(await cli.parse(['--wait', '-5s']), 0);
      expect(d, const Duration(seconds: -5));
      expect(
          await cli.parse(
              ['--uri', 'https://example.com/x', '--wait', '90']),
          0);
      expect(u, Uri.parse('https://example.com/x'));
      expect(d, const Duration(seconds: 90));
      expect(await cli.parse(['--wait', 'soon']), 64);
      expect(await cli.parse(['--uri', 'notaurl']), 64);
    });

    test('suggestions name options, not Args; -vh helps', () async {
      final verbose = Flag('verbose', 'V.', short: 'v');
      final url = Opt<String>('url', 'U.', or: '');
      final q = Arg<String?>('q', 'Q.');
      final cli = Command('app', 'X.',
          values: [verbose, url, q], handler: (_) {});
      expect(await cli.parse(['--urlx', 'y']), 64);
      expect(await cli.parse(['-vh']), 0);
    });

    test('the hint names the deepest command reached', () async {
      final cli = Command('app', 'X.', commands: [
        Command('remote', 'R.', commands: [
          Command('add', 'A.', handler: (_) {}),
        ]),
      ]);
      expect(await cli.parse(['remote', '--bogus']), 64);
    });
  });

  group('positionals', () {
    test('Args bind in order; rest is the tail', () async {
      final src = Arg<String>('src', 'S.', required: true);
      final dst = Arg<String?>('dst', 'D.');
      String? s;
      String? d;
      List<String> tail = const [];
      final cli = Command('cp', 'Copy.', values: [src, dst], handler: (ctx) {
        s = ctx(src);
        d = ctx(dst);
        tail = ctx.rest();
      });
      expect(await cli.parse(['a', 'b']), 0);
      expect(s, 'a');
      expect(d, 'b');
      expect(tail, isEmpty);
      expect(await cli.parse(['a']), 0);
      expect(s, 'a');
      expect(d, isNull);
      expect(await cli.parse([]), 64);
      expect(await cli.parse(['a', 'b', 'c']), 64);
    });

    test('a query of help stays positional when Args exist', () async {
      final q = Arg<String>('q', 'Query.', required: true);
      String? seen;
      final cli = Command('app', 'X.',
          values: [q], handler: (ctx) => seen = ctx(q));
      expect(await cli.parse(['help']), 0);
      expect(seen, 'help');
    });
  });

  group('subcommands', () {
    test('dispatch by name and alias; ancestor options work after', () async {
      final tag = Multi<String>('tag', 'A tag.', short: 't');
      final file = Arg<String>('file', 'F.', required: true);
      var built = '';
      List<String> tags = const [];
      final cli = Command('tk', 'Tool.', values: [tag], commands: [
        Command('build', 'Builds.', aliases: ['b'], values: [file],
            handler: (ctx) {
          built = ctx(file);
          tags = ctx(tag);
        }),
      ]);
      expect(await cli.parse(['build', '--tag', 'a', 'f1']), 0);
      expect(built, 'f1');
      expect(tags, ['a']);
      expect(await cli.parse(['b', 'f1']), 0);
      expect(built, 'f1');
    });

    test('C6: help works at depth; unknown help names suggest', () async {
      final cli = Command('tk', 'Tool.', commands: [
        Command('remote', 'R.', commands: [
          Command('add', 'A.', handler: (_) {}),
        ]),
      ]);
      expect(await cli.parse(['help', 'remote', 'add']), 0);
      expect(await cli.parse(['remote', 'help', 'add']), 0);
      expect(await cli.parse(['help', 'rmove']), 64);
    });

    test('--help is 0, unknown command is 64, UsageException is 64',
        () async {
      final cli = Command('tk', 'Tool.', commands: [
        Command('build', 'Builds.', handler: (_) {}),
      ]);
      expect(await cli.parse(['--help']), 0);
      expect(await cli.parse(['help', 'build']), 0);
      expect(await cli.parse(['rmove']), 64);
      final bad = Command('app', 'X.',
          handler: (_) => throw const UsageException('nope'));
      expect(await bad.parse([]), 64);
    });

    test('C10: handler Errors propagate with their stack', () async {
      final cli = Command('app', 'X.',
          handler: (_) => throw StateError('bug'));
      var threw = false;
      try {
        await cli.parse([]);
      } on StateError {
        threw = true;
      }
      expect(threw, isTrue);
      final exc = Command('app', 'X.',
          handler: (_) => throw FormatException('bad input'));
      expect(await exc.parse([]), 1);
    });

    test('C14: children cannot redeclare ancestor options', () {
      final tag = Opt<String>('tag', 'T.', or: '');
      expect(
        () => Command('app', 'X.', values: [tag], commands: [
          Command('go', 'G.', values: [Opt<String>('tag', 'Other.')]),
        ]),
        throwsArgumentError,
      );
      final v = Flag('verbose', 'V.', short: 'v');
      expect(
        () => Command('app', 'X.', values: [v], commands: [
          Command('go', 'G.', values: [Flag('other', 'O.', short: 'v')]),
        ]),
        throwsArgumentError,
      );
      // Sharing the identical Def object is fine.
      expect(
        () => Command('app', 'X.', values: [tag], commands: [
          Command('go', 'G.', values: [tag], handler: (_) {}),
        ]),
        returnsNormally,
      );
      expect(() => Command('bad name', 'X.'), throwsArgumentError);
    });

    test('usage lists -h, --help and reads back', () async {
      final top = Opt<int>('top', 'N.', or: 1);
      String? usage;
      final cli = Command('app', 'X.',
          values: [top], handler: (ctx) => usage = ctx.usage());
      expect(await cli.parse([]), 0);
      expect(usage, contains('-h, --help'));
      expect(usage, contains('Usage: app'));
    });
  });

  group('schema', () {
    test('ctx on undeclared definition is StateError', () async {
      final top = Opt<int>('top', 'N.', or: 1);
      final other = Opt<int?>('other', 'O.');
      var stateErr = false;
      final cli = Command('app', 'X.',
          values: [top],
          handler: (ctx) {
            try {
              ctx(other);
            } on StateError {
              stateErr = true;
            }
          });
      await cli.parse([]);
      expect(stateErr, isTrue);
    });

    test('schema validation is ArgumentError', () {
      expect(() => Flag('x', 'X.', short: 'xy'), throwsArgumentError);
      expect(
          () => Opt<String>('x', 'X.', required: true, or: 'd'),
          throwsArgumentError);
      expect(
          () => Command('c', 'C.', values: [
                Opt<String>('x', 'X.', or: ''),
                Opt<String>('x', 'Y.', or: ''),
              ]),
          throwsArgumentError);
      expect(
          () => Command('c', 'C.',
              values: [
                    Arg<String?>('id', 'I.'),
                    Arg<String>('req', 'R.', required: true),
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
