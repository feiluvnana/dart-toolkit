import 'dart:io';

import 'package:dart_toolkit/cli.dart';
import 'package:test/test.dart';

import 'support/capture.dart';
import 'support/child.dart';

/// Run [cli] expecting exit [code]; returns what it printed to stderr.
Future<String> fails(Command cli, List<String> argv, [int code = 64]) async {
  final r = await capture(() => cli.run(argv));
  expect(r.value, code, reason: r.err);
  return r.err;
}

/// Run [cli] expecting exit 0; returns what it printed to stdout.
Future<String> helps(Command cli, List<String> argv) async {
  final r = await capture(() => cli.run(argv));
  expect(r.value, 0, reason: r.err);
  return r.out;
}

void main() {
  valuesTests();
  group('options', () {
    test('typed Opt with default, reads and coerces', () async {
      final top = Opt<int>('top', 'N.', short: 'n', or: 10);
      int? seen;
      final cli = Command('app', 'X.', params: [top], handler: (ctx) => seen = ctx(top));
      expect(await cli.run([]), 0);
      expect(seen, 10);
      expect(await cli.run(['--top', '3']), 0);
      expect(seen, 3);
      expect(await cli.run(['-n4']), 0);
      expect(seen, 4);
      expect(await fails(cli, ['--top', 'soon']), contains('option "--top": expected an integer'));
    });

    test('T is inferred from or: and parse:', () async {
      final port = Opt('port', 'Port.', short: 'p', or: 8080);
      final since = Opt('since', 'Start date.', parse: DateTime.parse, or: DateTime(2020));
      // Static proof: no explicit type arguments above, yet these assign.
      Opt<int> checkPort = port;
      Opt<DateTime> checkSince = since;
      int? seenPort;
      DateTime? seenSince;
      final cli = Command(
        'app',
        'X.',
        params: [checkPort, checkSince],
        handler: (ctx) {
          seenPort = ctx(port);
          seenSince = ctx(since);
        },
      );
      expect(await cli.run([]), 0);
      expect(seenPort, 8080);
      expect(seenSince, DateTime(2020));
      expect(await cli.run(['--port', '1', '--since', '2026-10-08']), 0);
      expect(seenPort, 1);
      expect(seenSince, DateTime(2026, 10, 8));
    });

    test('V19: non-nullable reads as T, nullable as T?', () async {
      final out = Opt<String>('out', 'O.', short: 'o', or: 'd');
      final maybe = Opt<String?>('maybe', 'M.');
      String? s;
      String? n;
      final cli = Command(
        'app',
        'X.',
        params: [out, maybe],
        handler: (ctx) {
          s = ctx(out);
          n = ctx(maybe);
        },
      );
      expect(await cli.run([]), 0);
      expect(s, 'd');
      expect(n, isNull);
      expect(await cli.run(['--maybe', 'x']), 0);
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
      final cli = Command('app', 'X.', params: [color], handler: (ctx) => seen = ctx(color) ? 1 : 0);
      expect(await cli.run(['--no-color']), 0);
      expect(seen, 0);
      expect(await cli.run([]), 0);
      expect(seen, 1);
    });

    test('--no-name is rejected on a Flag without or: true', () async {
      final v = Flag('verbose', 'V.');
      final cli = Command('app', 'X.', params: [v], handler: (_) {});
      expect(await fails(cli, ['--no-verbose']), contains('Did you mean "--verbose"?'));
      expect(await cli.run(['--verbose']), 0);
    });

    test('a Duration default shows in parser syntax', () async {
      late String usage;
      final w = Opt('wait', 'W.', or: const Duration(minutes: 1, seconds: 30));
      final t = Opt('tick', 'T.', or: const Duration(milliseconds: 250));
      final z = Opt('zero', 'Z.', or: Duration.zero);
      await Command('app', 'X.', params: [w, t, z], handler: (c) => usage = c.usage()).run([]);
      expect(usage, contains('[default: 1m30s]'));
      expect(usage, contains('[default: 250ms]'));
      expect(usage, contains('[default: 0s]'));
      Duration? got;
      await Command('app', 'X.', params: [w], handler: (c) => got = c(w)).run(['--wait', '1m30s']);
      expect(got, const Duration(seconds: 90));
    });

    test('required Opt missing is 64', () async {
      final req = Opt<String>('token', 'T.', required: true);
      final cli = Command('app', 'X.', params: [req], handler: (_) {});
      expect(await fails(cli, []), contains('Missing option --token'));
      expect(await cli.run(['--token', 'x']), 0);
    });

    test('C3: a required parent Opt is checked when dispatching', () async {
      final token = Opt<String>('token', 'T.', required: true);
      final cli = Command(
        'app',
        'X.',
        params: [token],
        commands: [Command('go', 'Go.', handler: (_) {})],
      );
      expect(await fails(cli, ['go']), contains('Run "app go --help" for usage.'));
      expect(await cli.run(['--token', 'x', 'go']), 0);
    });

    test('C1/C2: parent Multi merges typed, before and after', () async {
      final tag = Multi<String>('tag', 'A tag.', short: 't');
      List<String> tags = const [];
      final cli = Command(
        'app',
        'X.',
        params: [tag],
        commands: [Command('go', 'Go.', handler: (ctx) => tags = ctx(tag))],
      );
      expect(await cli.run(['--tag', 'a', 'go', '--tag', 'b']), 0);
      expect(tags, ['a', 'b']);
    });

    test('C4: Multi with parse: reads as List<T>', () async {
      final col = Multi<Color>('col', 'C.', parse: Color.parse);
      List<Color> seen = const [];
      final cli = Command('app', 'X.', params: [col], handler: (ctx) => seen = ctx(col));
      expect(await cli.run(['--col', 'red', '--col', '#00ff00']), 0);
      expect(seen, [Color.red, const Color(0x00ff00)]);
      expect(await cli.run([]), 0);
      expect(seen, isEmpty);
    });

    test('C4b: Multi with values: takes comma lists too', () async {
      final kind = Multi('kind', 'K.', values: ['photo', 'reel', 'story']);
      List<String> seen = const [];
      final cli = Command('app', 'X.', params: [kind], handler: (ctx) => seen = ctx(kind));
      expect(await cli.run(['--kind=photo,reel', '--kind', 'story']), 0);
      expect(seen, ['photo', 'reel', 'story']);
      expect(await fails(cli, ['--kind=photo,nope']), contains('Invalid value "nope"'));
    });

    test('C5: a short h keeps --help', () async {
      final h = Opt<String>('host', 'H.', short: 'h', or: 'x');
      final cli = Command('app', 'X.', params: [h], handler: (_) {});
      expect(await helps(cli, ['--help']), contains('-h, --host <value>'));
      expect((await capture(() => cli.run(['-h', 'y']))).value, 0);
      expect(() => Flag('help', 'H.'), throwsArgumentError);
      expect(() => Opt<String>('help', 'H.', or: 'x'), throwsArgumentError);
    });

    test('grouped shorts, attached params, -- ends options', () async {
      final v = Flag('verbose', 'V.', short: 'v');
      final n = Opt<int>('n', 'N.', short: 'n', or: 0);
      final rest = Rest<String>('rest', 'R.');
      var vv = false;
      var nn = -1;
      List<String> tail = const [];
      final cli = Command(
        'app',
        'X.',
        params: [v, n, rest],
        handler: (ctx) {
          vv = ctx(v);
          nn = ctx(n);
          tail = ctx(rest);
        },
      );
      expect(await cli.run(['-vn3']), 0);
      expect((vv, nn), (true, 3));
      expect(await cli.run(['--', '-v']), 0);
      expect(tail, ['-v']);
      // -v=no consumes only itself (regression: the next token was skipped).
      expect(await cli.run(['-v=no', '-n', '7']), 0);
      expect((vv, nn), (false, 7));
    });

    test('-5 stays positional when no short answers to it', () async {
      final q = Arg<String?>('q', 'Query.');
      String? seen;
      final cli = Command('app', 'X.', params: [q], handler: (ctx) => seen = ctx(q));
      expect(await cli.run(['-5']), 0);
      expect(seen, '-5');
    });

    test('Duration, DateTime and Uri params; negative durations', () async {
      final wait = Opt<Duration>('wait', 'W.', or: Duration.zero);
      final when = Opt<DateTime?>('when', 'W.');
      final uri = Opt<Uri?>('uri', 'U.');
      Duration? d;
      DateTime? dt;
      Uri? u;
      final cli = Command(
        'app',
        'X.',
        params: [wait, when, uri],
        handler: (ctx) {
          d = ctx(wait);
          dt = ctx(when);
          u = ctx(uri);
        },
      );
      expect(await cli.run(['--wait', '1h30m', '--when', '2026-10-08']), 0);
      expect(d, const Duration(hours: 1, minutes: 30));
      expect(dt, DateTime(2026, 10, 8));
      expect(await cli.run(['--wait', '-5s']), 0);
      expect(d, const Duration(seconds: -5));
      expect(await cli.run(['--uri', 'https://example.com/x', '--wait', '90']), 0);
      expect(u, Uri.parse('https://example.com/x'));
      expect(d, const Duration(seconds: 90));
      expect(await fails(cli, ['--wait', 'soon']), contains('expected a duration such as 90s'));
      expect(await fails(cli, ['--wait', '99999999999999999d']), contains('expected a duration')); // wrapped negative
      expect(await fails(cli, ['--uri', 'notaurl']), contains('expected a URL'));
    });

    test('suggestions name options, not Args; -vh helps', () async {
      final verbose = Flag('verbose', 'V.', short: 'v');
      final url = Opt<String>('url', 'U.', or: '');
      final q = Arg<String?>('q', 'Q.');
      final cli = Command('app', 'X.', params: [verbose, url, q], handler: (_) {});
      expect(await fails(cli, ['--urlx', 'y']), contains('Did you mean "--url"?'));
      expect(await helps(cli, ['-vh']), contains('Usage: app [q] [options]'));
    });

    test('the hint names the deepest command reached', () async {
      final cli = Command(
        'app',
        'X.',
        commands: [
          Command('remote', 'R.', commands: [Command('add', 'A.', handler: (_) {})]),
        ],
      );
      expect(await fails(cli, ['remote', '--bogus']), contains('Unknown option --bogus'));
    });
  });

  group('positionals', () {
    test('Args bind in order; a positional nothing takes is an error', () async {
      final src = Arg<String>('src', 'S.', required: true);
      final dst = Arg<String?>('dst', 'D.');
      String? s;
      String? d;
      final cli = Command(
        'cp',
        'Copy.',
        params: [src, dst],
        handler: (ctx) {
          s = ctx(src);
          d = ctx(dst);
        },
      );
      expect(await cli.run(['a', 'b']), 0);
      expect(s, 'a');
      expect(d, 'b');
      expect(await cli.run(['a']), 0);
      expect(s, 'a');
      expect(d, isNull);
      expect(await fails(cli, []), contains('Missing argument <src>'));
      expect(await fails(cli, ['a', 'b', 'c']), contains('Unexpected argument "c"'));
    });

    test('Rest takes the positionals after the Args, typed', () async {
      final op = Arg<String>('op', 'O.', required: true);
      final ns = Rest<int>('n', 'N.', required: true, parse: int.parse);
      String? o;
      List<int> seen = const [];
      final cli = Command(
        'sum',
        'S.',
        params: [op, ns],
        handler: (ctx) {
          o = ctx(op);
          seen = ctx(ns);
        },
      );
      expect(await cli.run(['add', '1', '2', '3']), 0);
      expect(o, 'add');
      expect(seen, [1, 2, 3]);
      expect(await fails(cli, ['add']), contains('Missing argument <n>'));
      expect(await fails(cli, ['add', 'x']), contains('Invalid value "x" for argument <n>'));
      expect(await helps(cli, ['--help']), contains('Usage: sum <op> <n>... [options]'));
      final opt = Rest<String>('file', 'F.');
      var files = <String>['unset'];
      final ls = Command('ls', 'L.', params: [opt], handler: (ctx) => files = ctx(opt));
      expect(await ls.run([]), 0);
      expect(files, isEmpty);
      expect(await helps(ls, ['--help']), contains('Usage: ls [file...] [options]'));
      expect(await fails(Command('x', 'X.', handler: (_) {}), ['y']), contains('Unexpected argument "y"'));
      expect(() => Command('c', 'C.', params: [Rest<String>('a', 'A.'), Arg<String?>('b', 'B.')]), throwsArgumentError);
    });

    test('a query of help stays positional when Args exist', () async {
      final q = Arg<String>('q', 'Query.', required: true);
      String? seen;
      final cli = Command('app', 'X.', params: [q], handler: (ctx) => seen = ctx(q));
      expect(await cli.run(['help']), 0);
      expect(seen, 'help');
    });
  });

  group('commands', () {
    test('dispatch by name and alias; ancestor options work after', () async {
      final tag = Multi<String>('tag', 'A tag.', short: 't');
      final file = Arg<String>('file', 'F.', required: true);
      var built = '';
      List<String> tags = const [];
      final cli = Command(
        'tk',
        'Tool.',
        params: [tag],
        commands: [
          Command(
            'build',
            'Builds.',
            aliases: ['b'],
            params: [file],
            handler: (ctx) {
              built = ctx(file);
              tags = ctx(tag);
            },
          ),
        ],
      );
      expect(await cli.run(['build', '--tag', 'a', 'f1']), 0);
      expect(built, 'f1');
      expect(tags, ['a']);
      expect(await cli.run(['b', 'f1']), 0);
      expect(built, 'f1');
    });

    test('C6: help works at depth; unknown help names suggest', () async {
      final cli = Command(
        'tk',
        'Tool.',
        commands: [
          Command('remote', 'R.', commands: [Command('add', 'A.', handler: (_) {})]),
        ],
      );
      expect(await helps(cli, ['help', 'remote', 'add']), contains('Usage: tk remote add'));
      expect(await helps(cli, ['remote', 'help', 'add']), contains('Usage: tk remote add'));
      expect(await fails(cli, ['help', 'remot']), contains('Did you mean "remote"?'));
    });

    test('--help is 0, unknown command is 64, UsageException is 64', () async {
      final cli = Command('tk', 'Tool.', commands: [Command('build', 'Builds.', handler: (_) {})]);
      expect(await helps(cli, ['--help']), contains('build               Builds.'));
      expect(await helps(cli, ['help', 'build']), contains('Usage: tk build'));
      expect(await fails(cli, ['rmove']), contains('Unknown command "rmove"'));
      final bad = Command('app', 'X.', handler: (_) => throw const UsageException('nope'));
      expect(await fails(bad, []), contains('nope'));
    });

    test('C10: handler Errors propagate with their stack', () async {
      final cli = Command('app', 'X.', handler: (_) => throw StateError('bug'));
      var threw = false;
      try {
        await cli.run([]);
      } on StateError {
        threw = true;
      }
      expect(threw, isTrue);
      final exc = Command('app', 'X.', handler: (_) => throw FormatException('bad input'));
      expect(await fails(exc, [], 1), contains('FormatException: bad input'));
    });

    test('C14: children cannot redeclare ancestor options', () {
      final tag = Opt<String>('tag', 'T.', or: '');
      expect(
        () => Command(
          'app',
          'X.',
          params: [tag],
          commands: [
            Command('go', 'G.', params: [Opt<String>('tag', 'Other.')]),
          ],
        ),
        throwsArgumentError,
      );
      final v = Flag('verbose', 'V.', short: 'v');
      expect(
        () => Command(
          'app',
          'X.',
          params: [v],
          commands: [
            Command('go', 'G.', params: [Flag('other', 'O.', short: 'v')]),
          ],
        ),
        throwsArgumentError,
      );
      // Sharing the identical Def object is fine.
      expect(
        () => Command(
          'app',
          'X.',
          params: [tag],
          commands: [
            Command('go', 'G.', params: [tag], handler: (_) {}),
          ],
        ),
        returnsNormally,
      );
      expect(() => Command('bad name', 'X.'), throwsArgumentError);
    });

    test('usage lists -h, --help and reads back', () async {
      final top = Opt<int>('top', 'N.', or: 1);
      String? usage;
      final cli = Command('app', 'X.', params: [top], handler: (ctx) => usage = ctx.usage());
      expect(await cli.run([]), 0);
      expect(usage, contains('-h, --help'));
      expect(usage, contains('Usage: app'));
    });
  });

  group('arguments and commands', () {
    test('M3: a command cannot declare both', () {
      expect(
        () => Command('app', 'X.', params: [Arg<String>('file', 'F.')], commands: [Command('sub', 'S.')]),
        throwsArgumentError,
      );
    });
  });

  group('parse: errors', () {
    test('M5: an Error from parse: propagates, an Exception is usage', () async {
      final bug = Opt<int>('n', 'N.', or: 0, parse: (_) => throw RangeError('bug'));
      expect(Command('app', 'X.', params: [bug]).run(['--n', '1']), throwsA(isA<RangeError>()));
      final bad = Opt<int>('n', 'N.', or: 0, parse: (_) => throw Exception('no'));
      expect(await fails(Command('app', 'X.', params: [bad]), ['--n', '1']), contains('option "--n": no'));
    });
  });

  group('messages', () {
    test('a bad value with escapes is quoted inert', () async {
      final r = await runDart(
        '''
import 'dart:io';
import 'package:dart_toolkit/cli.dart';
Future<void> main(List<String> a) async {
  exitCode = await Command('app', 'X.', params: [Opt<int>('port', 'P.', or: 1)], handler: (_) {}).run(a);
}
''',
        args: ['--port', '1\x1b]0;PWN\x07'],
      );
      expect(r.exitCode, 64);
      expect(r.stderr, contains('1\uFFFD]0;PWN\uFFFD'));
      expect(r.stderr, isNot(contains('\x1b')));
    });

    test('Console prompts and log keep colour but drop other escapes', () async {
      final r = await runDart(
        '''
import 'package:dart_toolkit/console.dart';
Future<void> main() async {
  Console.log('\\x1b[32mok\\x1b[0m \\x1b]52;c;SGk=\\x07');
  print(await Console.ask('Q\\x1b]0;T\\x07?'));
}
''',
        stdin: const [(Duration.zero, 'x\n')],
      );
      expect(r.stderr, contains('\x1b[32mok\x1b[0m \uFFFD]52;c;SGk=\uFFFD'));
      expect(r.stderr, contains('Q\uFFFD]0;T\uFFFD?'));
    });
  });

  group('message style', () {
    const script = '''
import 'dart:io';
import 'package:dart_toolkit/cli.dart';
Future<void> main(List<String> a) async {
  final port = Opt<int>('port', 'P.', short: 'p', or: 1);
  final file = Arg<String>('file', 'F.', required: true);
  exitCode = await Command('app', 'X.', params: [port, file], handler: (_) {}).run(a);
}
''';
    Future<String> err(List<String> args) async {
      final r = await runDart(script, args: args);
      expect(r.exitCode, 64);
      return (r.stderr as String).split('\n').first;
    }

    test('one style, no trailing period on single-sentence errors', () async {
      expect(await err(['f', '--port']), 'Option --port needs a value');
      expect(await err(['f', '-p']), 'Option -p needs a value');
      expect(await err([]), 'Missing argument <file>');
      expect(await err(['f', 'g']), 'Unexpected argument "g"');
    });

    test('a bare group prints usage to stderr and exits 64', () async {
      final r = await runDart('''
import 'dart:io';
import 'package:dart_toolkit/cli.dart';
Future<void> main(List<String> a) async {
  exitCode = await Command('tk', 'Tool.', commands: [Command('build', 'B.', handler: (_) {})]).run(a);
}
''');
      expect(r.exitCode, 64);
      expect(r.stdout, isEmpty);
      expect(r.stderr, contains('Usage: tk'));
    });
  });

  group('environment', () {
    test('env: fills an option not given; the flag still wins; help names it', () async {
      const script = '''
import 'dart:io';
import 'package:dart_toolkit/cli.dart';
Future<void> main(List<String> a) async {
  final token = Opt<String?>('token', 'API token.', env: 'APP_TOKEN');
  final n = Opt('n', 'Count.', or: 1, env: 'APP_N');
  exitCode = await Command('app', 'X.', params: [token, n], handler: (c) => print('\${c(token)} \${c(n)}')).run(a);
}
''';
      expect((await runDart(script, env: {'APP_TOKEN': 'abc', 'APP_N': '7'})).stdout, 'abc 7\n');
      expect((await runDart(script, args: ['--token', 'cli'], env: {'APP_TOKEN': 'abc'})).stdout, 'cli 1\n');
      final bad = await runDart(script, env: {'APP_N': 'sk-live-hunter2'});
      expect(bad.exitCode, 64);
      expect(bad.stderr, contains(r'Invalid value for environment variable $APP_N: expected an integer'));
      expect(bad.stderr, isNot(contains('hunter2'))); // a value from the environment is never echoed
      expect((await runDart(script, args: ['--help'])).stdout, contains('[env: APP_TOKEN]'));
    });

    test('dotenv: loads KEY=VALUE before parsing, never over the real environment', () async {
      final dir = await Directory.systemTemp.createTemp('dotenv');
      addTearDown(() => dir.delete(recursive: true));
      await File('${dir.path}/.env')
          .writeAsString('# comment\nexport APP_TOKEN="from file"\nAPP_N=5 # five\nAPP_X=\'raw \\n\'\n');
      const script = '''
import 'dart:io';
import 'package:dart_toolkit/cli.dart';
Future<void> main(List<String> a) async {
  final token = Opt<String?>('token', 'API token.', env: 'APP_TOKEN');
  final n = Opt('n', 'Count.', or: 1, env: 'APP_N');
  final x = Opt<String?>('x', 'Raw.', env: 'APP_X');
  await Command('app', 'X.', params: [token, n, x], dotenv: '.env', handler: (c) => print('\${c(token)} \${c(n)} \${c(x)}')).run(a);
}
''';
      expect((await runDart(script, cwd: dir.path)).stdout, 'from file 5 raw \\n\n');
      expect((await runDart(script, cwd: dir.path, env: {'APP_N': '9'})).stdout, startsWith('from file 9 '));
      await File('${dir.path}/.env').delete();
      expect((await runDart(script, cwd: dir.path)).stdout, 'null 1 null\n');
    });
  });

  test('dotenv: a quoted value ends at its quote, comments after it go, escapes decode once', () async {
    final dir = await Directory.systemTemp.createTemp('dotenv2');
    addTearDown(() => dir.delete(recursive: true));
    await File('${dir.path}/.env')
        .writeAsString('A="abc123" # prod token\nB="C:\\\\new\\\\dir"\nC="say \\"hi\\"\\tok"\nD=\'it\'\'s\'\n');
    const script = '''
import 'package:dart_toolkit/cli.dart';
Future<void> main(List<String> a) async {
  final opts = [for (final k in ['a', 'b', 'c', 'd']) Opt<String?>(k, k, env: k.toUpperCase())];
  await Command('app', 'X.', params: opts, dotenv: '.env', handler: (c) => print([for (final o in opts) '[\${c(o)}]'].join())).run(a);
}
''';
    expect((await runDart(script, cwd: dir.path)).stdout, '[abc123][C:\\new\\dir][say "hi"\tok][it]\n');
  });

  // Regression: the dotenv values were one global, so a second Command run
  // in the same process saw the first one's file.
  test('dotenv: values belong to their run, not to the process', () async {
    final dir = await Directory.systemTemp.createTemp('dotenv3');
    addTearDown(() => dir.delete(recursive: true));
    await File('${dir.path}/.env').writeAsString('APP_T=from-file\n');
    const script = '''
import 'package:dart_toolkit/cli.dart';
Future<void> main(List<String> a) async {
  final t = Opt<String?>('t', 'T.', env: 'APP_T');
  await Command('one', 'X.', params: [t], dotenv: '.env', handler: (c) => print(c(t))).run(a);
  await Command('two', 'X.', params: [t], handler: (c) => print(c(t))).run(a);
}
''';
    expect((await runDart(script, cwd: dir.path)).stdout, 'from-file\nnull\n');
  });

  group('Opt(min:, max:)', () {
    test('bounds a value, in usage and in errors', () async {
      final q = Opt<int?>('quality', 'Quality.', min: 1, max: 100);
      int? seen;
      final cli = Command('app', 'X.', params: [q], handler: (c) => seen = c(q));
      expect(await cli.run(['--quality', '85']), 0);
      expect(seen, 85);
      expect(await fails(cli, ['--quality', '150']), contains('must be between 1 and 100'));
      expect(await fails(cli, ['--quality', '0']), contains('must be between 1 and 100'));
      expect(await helps(cli, ['--help']), contains('[1-100]'));
      final wait = Opt('wait', 'W.', or: const Duration(seconds: 1), min: Duration.zero);
      expect(
        await fails(Command('w', 'X.', params: [wait], handler: (_) {}), ['--wait', '-5s']),
        contains('at least 0s'),
      );
    });

    test('a default outside the bounds, or a type that does not order, is an ArgumentError', () {
      expect(() => Opt('n', 'N.', or: 0, min: 1), throwsArgumentError);
      expect(() => Opt<Uri?>('u', 'U.', min: Uri.parse('a:b')), throwsArgumentError);
    });
  });

  group('version:', () {
    test('--version prints name and version at any depth, skipping required checks', () async {
      final need = Opt<String>('need', 'N.', required: true);
      final cli = Command(
        'tool',
        'X.',
        version: '1.2.3',
        commands: [
          Command('sub', 'S.', params: [need], handler: (_) => fail('handler ran')),
        ],
      );
      expect(await helps(cli, ['--version']), 'tool 1.2.3\n');
      expect(await helps(cli, ['sub', '--version']), 'tool 1.2.3\n');
      expect(await helps(cli, ['--help']), contains('--version'));
    });

    test('without version: it is an unknown option; with it, a --version param is reserved', () async {
      expect(await fails(Command('t', 'X.', handler: (_) {}), ['--version']), contains('Unknown option --version'));
      expect(() => Command('t', 'X.', version: '1', params: [Opt<String?>('version', 'V.')]), throwsArgumentError);
    });
  });

  group('suggestions', () {
    test('L1: short options suggest only the case-swapped letter', () async {
      const script = '''
import 'dart:io';
import 'package:dart_toolkit/cli.dart';
Future<void> main(List<String> a) async {
  final v = Flag('verbose', 'V.', short: 'v');
  exitCode = await Command('app', 'X.', params: [v], handler: (_) {}).run(a);
}
''';
      Future<String> err(String arg) async {
        final r = await runDart(script, args: [arg]);
        expect(r.exitCode, 64);
        return r.stderr as String;
      }

      expect(await err('-x'), isNot(contains('Did you mean')));
      expect(await err('-V'), contains('Did you mean "-v"'));
    });
  });

  group('schema', () {
    test('ctx on undeclared definition is StateError', () async {
      final top = Opt<int>('top', 'N.', or: 1);
      final other = Opt<int?>('other', 'O.');
      var stateErr = false;
      final cli = Command(
        'app',
        'X.',
        params: [top],
        handler: (ctx) {
          try {
            ctx(other);
          } on StateError {
            stateErr = true;
          }
        },
      );
      await cli.run([]);
      expect(stateErr, isTrue);
    });

    test('schema validation is ArgumentError', () {
      expect(() => Flag('x', 'X.', short: 'xy'), throwsArgumentError);
      expect(() => Opt<String>('x', 'X.', required: true, or: 'd'), throwsArgumentError);
      expect(
        () => Command(
          'c',
          'C.',
          params: [
            Opt<String>('x', 'X.', or: ''),
            Opt<String>('x', 'Y.', or: ''),
          ],
        ),
        throwsArgumentError,
      );
      expect(
        () => Command('c', 'C.', params: [Arg<String?>('id', 'I.'), Arg<String>('req', 'R.', required: true)]),
        throwsArgumentError,
      );
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

enum _Section { photos, reels }

void valuesTests() {
  group('cli values:', () {
    test('parses an enum by name, case-insensitive, and rejects the rest', () async {
      _Section? got;
      final s = Arg('section', 'What.', values: _Section.values, or: _Section.photos);
      final cli = Command('app', 'X.', params: [s], handler: (c) => got = c(s));
      expect(await cli.run(['REELS']), 0);
      expect(got, _Section.reels);
      expect(await cli.run([]), 0);
      expect(got, _Section.photos);
      expect(await fails(cli, ['stories']), contains('expected photos, reels'));
    });

    test('usage lists the values', () async {
      late String usage;
      final s = Arg('section', 'What.', values: _Section.values, or: _Section.photos);
      await Command('app', 'X.', params: [s], handler: (c) => usage = c.usage()).run([]);
      expect(usage, contains('<photos|reels>'));
    });

    test('a long values list moves after the help, so the flag column stays narrow (regression); every value as default reads all', () async {
      late String usage;
      final kinds = Multi(
        'kind',
        'What.',
        values: ['posts', 'stories', 'highlights', 'photos', 'videos'],
        or: const [
          'posts', 'stories', 'highlights', 'photos', 'videos', //
        ],
      );
      final short = Opt<String?>('mode', 'How.', values: ['a', 'b']);
      await Command('app', 'X.', params: [kinds, short], handler: (c) => usage = c.usage()).run([]);
      expect(usage, contains('--kind <value>...'));
      expect(usage, contains('One of: posts, stories, highlights, photos, videos. [default: all]'));
      expect(usage, contains('--mode <a|b>'));
    });

    test('values and parse together are an ArgumentError', () {
      expect(
        () => Arg<_Section>('s', 'S.', values: _Section.values, parse: _Section.values.byName),
        throwsArgumentError,
      );
    });
  });

  test('cli prints a failure as its message, not the SDK toString', () async {
    final r = await runDart(
      '''
import 'dart:io';
import 'package:dart_toolkit/cli.dart';
import 'package:dart_toolkit/json.dart';
Future<void> main(List<String> a) async {
  exitCode = await Command('app', 'X.', handler: (c) {
    if (a.first == 'json') Json.parse('{bad');
    throw Exception('plain failure');
  }).run(const []);
}
''',
      args: ['plain'],
    );
    expect(r.exitCode, 1);
    expect(r.stderr, 'plain failure\n');
    final j = await runDart('''
import 'dart:io';
import 'package:dart_toolkit/cli.dart';
import 'package:dart_toolkit/json.dart';
Future<void> main(List<String> a) async {
  await Command('app', 'X.', handler: (c) => Json.parse('{bad')).run(a);
}
''');
    expect(j.exitCode, 1, reason: 'run sets exitCode itself');
    expect(j.stderr, startsWith('invalid JSON'));
    final ok = await runDart('''
import 'dart:io';
import 'package:dart_toolkit/cli.dart';
Future<void> main(List<String> a) async {
  await Command('app', 'X.', handler: (c) => exitCode = 3).run(a);
}
''');
    expect(ok.exitCode, 3, reason: 'a success leaves the handler\'s code alone');
  });
}
