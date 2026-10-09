import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_toolkit/cli.dart';
import 'package:dart_toolkit/testing.dart';
import 'package:test/test.dart' hide Retry;

import 'support.dart';

enum Target { dev, prod }

/// A batch of [items], each reporting [steps] amounts of 1 KB, [gap] apart, failing where [fail] says.
Batch<String, int> _work(
  List<String> items, {
  int steps = 3,
  Duration gap = const Duration(milliseconds: 20),
  Set<String> fail = const {},
}) => items.parallelize(
  (item) => Task.run(item, (work) async {
    for (var k = 1; k <= steps; k++) {
      work.amount(k * 1024, total: steps * 1024);
      await Future<void>.delayed(gap);
    }
    if (fail.contains(item)) throw FormatException('bad $item');
    return item.length;
  }),
);

/// What [body] writes to stdout and stderr, uncoloured, at [level].
Future<(String, String)> _captured(FutureOr<void> Function() body, {LogLevel? level}) async {
  final out = StringBuffer(), err = StringBuffer();
  await Io.scope(
    () => Console.scope(body, level: level),
    stdout: out,
    stderr: err,
    color: false,
  );
  return ('$out', '$err');
}

Future<void> _pump([int turns = 5]) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('drawing any work', () {
    test('show works on a plain future, and answers what await answers', () async {
      final err = StringBuffer();
      final value = await Io.scope(() => Future.value(3).show('Three'), stderr: err);
      expect(value, 3);
      await expectLater(
        Io.scope(() => Future<int>.error(const FormatException('no')).show('Bad'), stderr: err),
        throwsFormatException,
      );
    });

    test('the same task gives the same tally, so a view can ask for it every frame', () async {
      final task = Task.run('t', (work) => Future<void>.delayed(const Duration(milliseconds: 5)));
      expect(identical(Tally.task(task), Tally.task(task)), isTrue);
      await task;
      final batch = [1].parallelize((i) => i);
      expect(identical(Tally.batch(batch), Tally.batch(batch)), isTrue);
      await batch;
    });
  });

  group('Cli: values and their types', () {
    test('Option.of reads as the coercion does; help shows the type and the default', () async {
      final wait = Option.of<Duration>('wait', 'Between pages').or(const Duration(seconds: 90));
      final since = Option.of<DateTime>('since', 'Not before');
      final ratio = Option.of<double>('ratio', 'Share', env: 'TK_TEST_RATIO');
      final seen = <Object?>[];
      final cli = Cli(
        'Demo.',
        name: 'demo',
        values: [wait, since, ratio],
        handler: (ctx) => seen.addAll([ctx(wait), ctx(since), ctx(ratio)]),
      );
      await Env.scope(() async {
        Env.set('TK_TEST_RATIO', '0.5');
        expect((await cli.test(['--wait', '1m30s', '--since', '2026-10-08'])).exitCode, 0);
      });
      expect(seen, [const Duration(minutes: 1, seconds: 30), DateTime.utc(2026, 10, 8), 0.5]);
      final bad = await cli.test(['--wait', 'soon']);
      expect(bad.exitCode, 64);
      expect(bad.stderr, contains('Invalid value "soon" for option "--wait": expected a duration'));
      expect(bad.stderr, contains('Run "demo --help" for usage.'));
      final help = await cli.test(['--help']);
      expect(
        help.stdout,
        allOf(contains('--wait <duration>'), contains('[default: 1m 30s]'), contains('[env: TK_TEST_RATIO]')),
      );
    });

    test('a repeated value reads back as the list its declaration names', () async {
      final tags = Option.of<String>('tag', 'A tag').many();
      final ports = Arg.of<int>('ports', 'Ports').many();
      final cli = Cli(
        't',
        values: [tags, ports],
        handler: (ctx) {
          final List<String> t = ctx(tags);
          final List<int> p = ctx(ports);
          Console.line('${t.join(',')}|${p.fold(0, (a, b) => a + b)}');
        },
      );
      expect((await cli.test(['--tag', 'a', '--tag', 'b', '1', '2'])).stdout.trim(), 'a,b|3');
      expect((await cli.test([])).stdout.trim(), '|0');
    });

    test('the steps cannot contradict each other, and say so in the type', () {
      final Defaulted<int> top = Option.of<int>('top', 'How many').or(10);
      final Required<String> to = Option.of<String>('to', 'Where').required();
      final Many<String> tags = Option.of<String>('tag', 'A tag').many();
      final Required<List<String>> files = Arg.of<String>('files', 'Inputs').many().required();
      final Defaulted<bool> color = Option.flag('color', 'Colour').or(true);
      expect([top, to, tags, files, color], hasLength(5));
    });

    test('Option.of<bool> is refused: a yes-or-no option is a flag (CLI-22)', () {
      expect(() => Option.of<bool>('dry', 'Dry run'), throwsArgumentError);
      expect(() => Option.of<List<int>>('x', 'x'), throwsArgumentError);
      expect(() => Option.among('env', 'Where', values: Target.values).or(Target.dev), returnsNormally);
      expect(() => Option.of<int>('-x', 'x'), throwsArgumentError);
      expect(() => Option.of<int>('x', 'x', short: 'xy'), throwsArgumentError);
    });

    test('a variadic argument comes last and an optional one after the required (CLI-24)', () {
      final rest = Arg.of<String>('rest', 'Rest').many();
      final id = Arg.of<String>('id', 'Id').required();
      final maybe = Arg.of<String>('maybe', 'Maybe');
      expect(() => CliCommand('c', 'c', values: [rest, id]), throwsArgumentError);
      expect(() => CliCommand('c', 'c', values: [maybe, id]), throwsArgumentError);
      expect(() => CliCommand('c', 'c', values: [id, maybe]), returnsNormally);
      final top = Option.of<int>('top', 'x');
      expect(() => CliCommand('c', 'c', values: [top, top]), throwsArgumentError);
    });

    test('arguments bind in order; a many takes the rest, a required many insists', () async {
      final id = Arg.of<String>('id', 'Id').required();
      final count = Arg.of<int>('count', 'How many').or(1);
      final files = Arg.of<String>('files', 'Files').many();
      final got = <Object?>[];
      final cli = Cli(
        'x',
        name: 'app',
        values: [id, count, files],
        handler: (ctx) => got.addAll([ctx(id), ctx(count), ctx(files)]),
      );
      await cli.test(['a', '3', 'f1', 'f2']);
      expect(got, [
        'a',
        3,
        ['f1', 'f2'],
      ]);
      got.clear();
      await cli.test(['a']);
      expect(got, ['a', 1, <String>[]]);
      expect((await cli.test([])).stderr, contains('Missing argument <id>'));
      final many = Arg.of<String>('paths', 'Paths').many().required();
      final strict = Cli('x', name: 'app', values: [many], handler: (_) {});
      expect((await strict.test([])).exitCode, 64);
      expect((await strict.test(['--', '-x'])).exitCode, 0, reason: 'after -- every word is positional');
    });

    test('ctx(value) on a value this command does not declare is a StateError (CLI-12)', () async {
      final declared = Option.of<int>('n', 'n');
      final other = Option.of<int>('m', 'm');
      Object? error;
      final cli = Cli(
        'x',
        name: 'app',
        values: [declared],
        handler: (ctx) {
          try {
            ctx(other);
          } catch (e) {
            error = e;
          }
        },
      );
      await cli.test([]);
      expect(error, isA<StateError>());
    });

    test('options combine, attach their values, repeat with many, and read negatives', () async {
      final verbose = Option.flag('loud', 'Loud', short: 'l');
      final jobs = Option.of<int>('jobs', 'Jobs', short: 'j').or(1);
      final tags = Option.of<String>('tag', 'Tag', short: 't').many();
      final offset = Option.of<int>('offset', 'Offset');
      final got = <Object?>[];
      final cli = Cli(
        'x',
        name: 'app',
        values: [verbose, jobs, tags, offset],
        handler: (ctx) {
          got.addAll([ctx(verbose), ctx(jobs), ctx(tags), ctx(offset)]);
        },
      );
      await cli.test(['-lj4', '-t', 'a', '--tag=b', '--offset', '-5']);
      expect(got, [
        true,
        4,
        ['a', 'b'],
        -5,
      ]);
      got.clear();
      await cli.test(['--loud=false']);
      expect(got.first, false);
      expect((await cli.test(['--loud=maybe'])).stderr, contains('a flag takes true or false'));
    });

    test('a flag on by default is turned off by --no-name and shown as --[no-]name', () async {
      final color = Option.flag('color', 'Colour output').or(true);
      bool? seen;
      final cli = Cli('x', name: 'app', values: [color], handler: (ctx) => seen = ctx(color));
      await cli.test([]);
      expect(seen, isTrue);
      await cli.test(['--no-color']);
      expect(seen, isFalse);
      expect((await cli.test(['-h'])).stdout, contains('--[no-]color'));
    });

    test('a typo gets a did-you-mean, and a required option names its variable', () async {
      final token = Option.of<Secret>('token', 'API token', env: 'TK_TEST_TOKEN').required();
      Secret? seen;
      final cli = Cli('x', name: 'app', values: [token], handler: (ctx) => seen = ctx(token));
      expect((await cli.test(['--tokn', 'x'])).stderr, contains('Did you mean "--token"?'));
      expect((await cli.test([])).stderr, contains('Missing option --token (or set TK_TEST_TOKEN)'));
      await cli.test(['--token', 'hunter2']);
      expect(seen?.reveal, 'hunter2');
      expect('$seen', '•••');
    });

    test('built-ins yield to declared names, and the help says so (CLI-28)', () async {
      final quality = Option.of<int>('quality', 'Quality', short: 'q').or(80);
      int? seen;
      final cli = Cli('x', name: 'app', values: [quality], handler: (ctx) => seen = ctx(quality));
      await cli.test(['-q', '50']);
      expect(seen, 50);
      final help = (await cli.test(['--help'])).stdout;
      expect(help, contains('-q is --quality here'));
      expect(help, contains('    --quiet'));
    });

    test('subcommands dispatch by name and alias; none named is a usage error, exit 64', () async {
      final ran = <String>[];
      final cli = Cli(
        'x',
        name: 'app',
        version: '1.2.0',
        commands: [
          CliCommand('remove', 'Remove it', aliases: ['rm'], handler: (_) => ran.add('remove')),
        ],
      );
      await cli.test(['rm']);
      expect(ran, ['remove']);
      final none = await cli.test([]);
      expect(none.exitCode, 64);
      expect(none.stderr, contains('Usage:'));
      expect((await cli.test(['--version'])).stdout, 'app 1.2.0\n');
      expect((await cli.test(['help', 'remove'])).stdout, contains('Usage: app remove'));
      expect((await cli.test(['rmove'])).stderr, contains('Did you mean "remove"?'));
    });
  });

  group('Cli: the run', () {
    test('a handler fails by throwing: UsageException 64, anything else 1 in one line', () async {
      final usage = await Cli('x', name: 'app', handler: (_) => throw const UsageException('no files match')).test([]);
      expect(usage.exitCode, 64);
      expect(usage.stderr, contains('no files match'));
      final failed = await Cli(
        'x',
        name: 'app',
        handler: (_) => throw const FormatException('bad\nsecond line'),
      ).test([]);
      expect(failed.exitCode, 1);
      expect(failed.stderr.trim().split('\n'), hasLength(1));
      expect(failed.stderr, isNot(contains('#0')), reason: 'the trace is for -v');
      final verbose = await Cli('x', name: 'app', handler: (_) => throw StateError('bug')).test(['-v']);
      expect(verbose.stderr, contains('#0'));
      final timeout = await Cli('x', name: 'app', handler: (_) => throw TimeoutException('slow')).test([]);
      expect(timeout.exitCode, 124);
    });

    test('ctx.defer runs at the end of the run, last first, however it ends', () async {
      final order = <String>[];
      final cli = Cli(
        'x',
        name: 'app',
        handler: (ctx) {
          ctx.defer(() => order.add('first'));
          ctx.defer(() => order.add('second ${ctx.ended == null}'));
          throw StateError('boom');
        },
      );
      await cli.test([]);
      expect(order, ['second false', 'first']);
    });

    test('a cleanup past the ten seconds is cut short, and the run says so', () async {
      final clock = Clock.fake();
      final cli = Cli('x', name: 'app', handler: (ctx) => ctx.defer(() => Completer<void>().future));
      final result = Clock.scope(() => cli.test([]), clock: clock);
      await _pump(20);
      await clock.advance(const Duration(seconds: 11));
      final r = await result;
      expect(r.stderr, contains('1 cleanup cut short after 10s'));
    });

    test('ctx.store is the program\'s own Store.app', () async {
      final dir = tempDir();
      String? folder;
      await Env.scope(() async {
        Env.set('DART_TOOLKIT_STORE', dir);
        await Cli('x', name: 'books', handler: (ctx) => folder = ctx.store.folder).test([]);
      });
      expect(folder, endsWith('books'));
    });

    test('Console.exit unwinds to the run: the message, the code, the cleanups (CLI-26, CON-6)', () async {
      var cleaned = false;
      final cli = Cli(
        'x',
        name: 'app',
        handler: (ctx) async {
          ctx.defer(() => cleaned = true);
          await [1, 2].parallelize((i) => i == 2 ? Console.exit('stop here', code: 3) : i);
        },
      );
      final r = await cli.test([]);
      expect(r.exitCode, 3);
      expect(r.stderr, contains('stop here'));
      expect(r.stderr, isNot(contains('Instance of')));
      expect(cleaned, isTrue);
    });

    test('a print in the handler is a line; drawn work that failed exits 1 with no second line', () async {
      final cli = Cli(
        'x',
        name: 'app',
        handler: (_) async {
          print('from print');
          await _work(['a', 'b'], fail: {'b'}).progress('Fetch');
          await Future<void>.delayed(const Duration(milliseconds: 200));
        },
      );
      final r = await cli.test([]);
      expect(r.stdout, 'from print\n');
      expect(r.exitCode, 1);
      expect('failed'.allMatches(r.stderr).length, 1, reason: r.stderr);
      expect(r.stderr, contains('Fetch: 1 of 2 failed'));
    });

    test('-v lines every warning the work gives that nothing drew (§11.2)', () async {
      final cli = Cli('x', name: 'app', handler: (_) => Task.run('job', (work) => work.warn('slow mirror')));
      expect((await cli.test(['-v'])).stderr, contains('slow mirror'));
      expect((await cli.test([])).stderr, isNot(contains('slow mirror')));
    });

    test('run exits with the code, and ^C cancels the work and runs its cleanups', () async {
      final r = await _script('''
        Future<void> main(List<String> a) => Cli('x', name: 'demo', handler: (_) => throw const UsageException('nope')).run(a);
      ''');
      expect(r.exitCode, 64);
      final process = await _start('''
        Future<void> main(List<String> a) => Cli('x', name: 'demo', handler: (ctx) async {
          ctx.defer(() => print('cleanup ran'));
          print('ready');
          await Future<void>.delayed(const Duration(minutes: 1));
        }).run(a);
      ''');
      final out = StringBuffer();
      final ready = Completer<void>();
      process.stdout.transform(utf8.decoder).listen((s) {
        out.write(s);
        if (s.contains('ready') && !ready.isCompleted) ready.complete();
      });
      final err = process.stderr.transform(utf8.decoder).join();
      await ready.future.timeout(const Duration(seconds: 30));
      process.kill(ProcessSignal.sigint);
      expect(await process.exitCode.timeout(const Duration(seconds: 20)), 130);
      expect('$out', contains('cleanup ran'));
      expect(await err, contains('Interrupted'));
    }, testOn: '!windows');

    test('^C while a child owns the terminal is the child\'s: the run goes on (X-14)', () async {
      final process = await _start('''
        import 'package:dart_toolkit/src/core.dart' show ProcessBridge;
        Future<void> main(List<String> a) => Cli('x', name: 'demo', handler: (ctx) async {
          ProcessBridge.interactive++;
          print('ready');
          await Future<void>.delayed(const Duration(seconds: 2));
          ProcessBridge.interactive--;
          print('survived');
        }).run(a);
      ''');
      final out = StringBuffer();
      final ready = Completer<void>();
      process.stdout.transform(utf8.decoder).listen((s) {
        out.write(s);
        if (s.contains('ready') && !ready.isCompleted) ready.complete();
      });
      process.stderr.drain<void>().ignore();
      await ready.future.timeout(const Duration(seconds: 30));
      process.kill(ProcessSignal.sigint);
      expect(await process.exitCode.timeout(const Duration(seconds: 20)), 0);
      expect('$out', contains('survived'));
    }, testOn: '!windows');

    test('completion scripts are built from the tree, and never offer files for numbers (CLI-29)', () async {
      final n = Option.of<int>('count', 'How many');
      final cli = Cli(
        'x',
        name: 'app',
        values: [n],
        commands: [CliCommand('go', 'Go', handler: (_) {})],
      );
      final bash = (await cli.test(['--completion', 'bash'])).stdout;
      expect(bash, allOf(contains('complete -o default -F _app_completion app'), contains('--count'), contains('go')));
      expect((await cli.test(['--completion', 'zsh'])).exitCode, 0);
      expect((await cli.test(['--completion', 'fish'])).stdout, contains('complete -c app'));
      expect((await cli.test(['--completion', 'tcsh'])).exitCode, 64);
    });

    test('a missing value names the option as it was written', () async {
      final top = Option.of<int>('top', 'How many', short: 'n');
      final cli = Cli('x', name: 'app', values: [top], handler: (_) {});
      expect((await cli.test(['-n'])).stderr, contains('Option -n needs a value'));
      expect((await cli.test(['--top'])).stderr, contains('Option --top needs a value'));
    });

    test("a subcommand handler's UsageException points at that command's help", () async {
      final cli = Cli(
        'x',
        name: 'app',
        commands: [CliCommand('build', 'Builds', handler: (_) => throw const UsageException('bad id'))],
      );
      final result = await cli.test(['build']);
      expect(result.exitCode, 64);
      expect(result.stderr, contains('Run "app build --help" for usage.'));
    });

    group('completion scripts', () {
      final out = Option.of<String>('out', 'Out', short: 'o');
      final mode = Option.among('mode', 'Mode', values: ['fast', 'dry run', "it's", r'$HOME']);
      Cli tree() => Cli(
        'x',
        name: 'app',
        values: [out],
        commands: [
          CliCommand('build', 'Builds', values: [mode], handler: (_) {}),
        ],
      );

      /// What bash offers for [words], the last one being typed, from the script `app` prints.
      Future<List<String>> bash(List<String> words) async {
        final script = (await tree().test(['--completion', 'bash'])).stdout;
        final quoted = words.map((w) => "'${w.replaceAll("'", r"'\''")}'").join(' ');
        final r = await Process.run('bash', [
          '-c',
          '$script\nCOMP_WORDS=($quoted); COMP_CWORD=${words.length - 1}; _app_completion; printf "%s\\n" "\${COMPREPLY[@]}"',
        ]);
        return '${r.stdout}'.split('\n').where((l) => l.isNotEmpty).toList();
      }

      test('bash offers a choice as it goes on the command line, quotes and dollars kept', () async {
        expect(await bash(['app', 'build', '--mode', '']), ['fast', r'dry\ run', r"it\'s", r'\$HOME']);
        expect(await bash(['app', 'build', '--mode', 'i']), [r"it\'s"]);
      }, testOn: '!windows');

      test('bash does not take an option value for a command', () async {
        expect(await bash(['app', '-o', 'build', '']), contains('--out'));
        expect(await bash(['app', '-o', 'build', '']), isNot(contains('--mode')));
        expect(await bash(['app', 'build', '']), contains('--mode'));
      }, testOn: '!windows');

      test('zsh and fish escape what their shells evaluate', () async {
        final zsh = (await tree().test(['--completion', 'zsh'])).stdout;
        expect(zsh, contains(r"(fast dry\ run it\'\''s \$HOME)"));
        expect(zsh, contains("'app:-o'"), reason: 'the walk skips an option value');
        final fish = (await tree().test(['--completion', 'fish'])).stdout;
        expect(fish, contains(r"-xa 'fast dry\\ run it\\\'s \\$HOME'"));
        expect(fish, contains("case 'app:--out' 'app:-o'"));
      });

      test("fish gives each built-in its own letter", () async {
        final fish = (await tree().test(['--completion', 'fish'])).stdout;
        expect(fish, allOf(contains('-l verbose -d \'Show debug output\' -s v'), contains('-s q'), contains('-s h')));
        expect(RegExp(r'-l (verbose|quiet) .* -s h').hasMatch(fish), isFalse);
      });
    });
  });

  group('Console: logs', () {
    test('info, ok and line go to stdout; debug, warn and error to stderr (CLI-32)', () async {
      final (out, err) = await _captured(() {
        Console.info('i');
        Console.ok('o');
        Console.line('plain');
        Console.line();
        Console.warn('w');
        Console.error('e');
        Console.debug('d');
      }, level: LogLevel.debug);
      expect(out, 'ℹ i\n✓ o\nplain\n\n');
      expect(err, '⚠ w\n✖ e\n· d\n');
    });

    test('Console.scope sets the level and the theme for its body, and inherits what it does not set', () async {
      final (out, err) = await _captured(() async {
        Console.debug('hidden');
        await Console.scope(() async {
          Console.info('hidden too');
          Console.warn('shown');
          await Console.scope(
            () => Console.warn('marked'),
            theme: const ConsoleTheme(
              palette: Palette(marks: Marks(warn: 'W')),
            ),
          );
        }, level: LogLevel.warn);
      });
      expect(out, isEmpty);
      expect(err, '⚠ shown\nW marked\n');
      expect(() => Console.scope(() {}, theme: const ConsoleTheme(rows: 0)), throwsArgumentError);
      expect(
        () => Console.scope(
          () {},
          theme: const ConsoleTheme(palette: Palette(frames: [])),
        ),
        throwsArgumentError,
      );
      expect(
        () => Console.scope(
          () {},
          theme: const ConsoleTheme(palette: Palette(interval: Duration.zero)),
        ),
        throwsArgumentError,
      );
    });

    test('a builder owns its line; the default wraps it', () async {
      final theme = ConsoleTheme(log: (l) => '[${l.level.name}] ${const ConsoleTheme().log(l)}');
      final (out, _) = await _captured(() => Console.scope(() => Console.info('x'), theme: theme));
      expect(out, '[info] ℹ x\n');
    });

    test('tee appends every line, unstyled and timestamped, failures and endings included (CON-15)', () async {
      final dir = tempDir();
      final log = '$dir/run.log';
      await _captured(() async {
        final untee = Console.tee(log);
        Console.ok('synced');
        await _work(['a', 'b'], fail: {'b'}).show('Fetch').then((_) {}, onError: (Object _) {});
        untee();
        Console.ok('not teed');
      });
      final lines = File(log).readAsLinesSync();
      expect(lines.first, matches(RegExp(r'^\d{4}-\d\d-\d\dT[\d:.]+Z ✓ synced$')));
      expect(
        lines.join('\n'),
        allOf(contains('✖ b: FormatException: bad b'), contains('Fetch: 1 of 2 failed'), contains('✓ a')),
      );
      expect(lines.join('\n'), isNot(contains('not teed')));
    });

    test('rule draws across the terminal in the palette\'s border', () async {
      final term = FakeTerminal(width: 20, height: 5);
      await Io.scope(() => Console.rule('Hi'), terminal: term);
      expect(term.screen, '─────── Hi ────────');
    });

    test('Style\'s text functions measure in cells and the ellipsis follows the palette', () {
      expect(Style.width('\x1b[31m日本\x1b[0m'), 4);
      expect(Style.plain('\x1b[31mred\x1b[0m'), 'red');
      expect(Style.truncate('abcdefgh', 5), 'abcd…');
      expect(Style.truncate('abcdefgh', 5, ellipsis: '...'), 'ab...');
      expect(Style.pad('ab', 4, align: Align.right), '  ab');
      expect(Style.wrap('one two three', 7), ['one two', 'three']);
      expect(Io.scope(() => 'docs'.link(Uri.parse('https://x.dev')), color: false), completion('docs'));
      expect(Palette.ascii.ellipsis, '...');
      expect('x'.red, isA<String>());
    });
  });

  group('Console: prompts', () {
    Stream<List<int>> typed(String text) => Stream.value(utf8.encode(text));

    Future<(T, String)> answering<T>(String input, Future<T> Function() prompt) async {
      final err = StringBuffer();
      final value = await Io.scope(prompt, stdin: typed(input), stderr: err, color: false);
      return (value, '$err');
    }

    test('ask without or: requires an answer; with or: Enter takes it (CLI-20)', () async {
      final (name, err) = await answering('\n  Ada \n', () => Console.ask('Name'));
      expect(name, 'Ada');
      expect(err, contains('An answer is required.'));
      expect((await answering('\n', () => Console.ask('Note', or: ''))).$1, '');
      await expectLater(answering('', () => Console.ask('Name')), throwsA(isA<MissingException>()));
      expect((await answering('', () => Console.ask('Port', or: 8080))).$1, 8080);
    });

    test('ask<T> reads a T; the parse function\'s message is shown and it asks again', () async {
      final (port, err) = await answering('eighty\n81\n', () => Console.ask<int>('Port'));
      expect(port, 81);
      expect(err, contains('Invalid int'));
      final (date, err2) = await answering('soon\n2026-10-08\n', () => Console.ask('When', parse: DateTime.parse));
      expect(date, DateTime.parse('2026-10-08'));
      expect(err2, contains('Invalid date format'));
      expect(() => Console.ask<Target>('Env'), throwsArgumentError);
    });

    test('confirm takes y or n, Enter takes or:, and no answer without or: is never a yes', () async {
      expect((await answering('maybe\ny\n', () => Console.confirm('Go?'))).$1, isTrue);
      expect((await answering('\n', () => Console.confirm('Go?', or: false))).$1, isFalse);
      await expectLater(answering('', () => Console.confirm('Deploy?')), throwsA(isA<MissingException>()));
    });

    test('secret answers a Secret, printed as •••', () async {
      final (pw, _) = await answering('hunter2\n', () => Console.secret('Password'));
      expect(pw.reveal, 'hunter2');
      expect('$pw', '•••');
    });

    test('pick and pickMany without a terminal number the choices', () async {
      final (env, err) = await answering('9\n2\n', () => Console.pick('Target', Target.values));
      expect(env, Target.prod);
      expect(err, contains('1) dev'));
      expect((await answering('\n', () => Console.pick('Target', Target.values, or: Target.dev))).$1, Target.dev);
      expect((await answering('1, prod\n', () => Console.pickMany('Targets', Target.values))).$1, Target.values);
      await expectLater(answering('', () => Console.pick('Target', Target.values)), throwsA(isA<MissingException>()));
      expect(() => Console.pick('T', <String>[]), throwsArgumentError);
      expect(() => Console.pick('T', ['a'], or: 'b'), throwsArgumentError);
    });

    test('pick on a terminal runs on the Choice model: arrows, filter, Enter (CLI-17, TUI-6)', () async {
      final term = FakeTerminal(width: 40, height: 10);
      final picked = Io.scope(() => Console.pick('Server', ['alpha', 'beta', 'gamma'], filter: true), terminal: term);
      await _pump();
      expect(term.screen, contains('› alpha'));
      term.type('gm');
      await _pump();
      expect(term.screen, contains('› gamma'));
      expect(term.screen, isNot(contains('beta')));
      term.press(KeyPress.enter);
      expect(await picked, 'gamma');
      expect(term.screen, 'Server: gamma');
      expect(term.isCursorVisible, isTrue);
    });

    test('pickMany on a terminal checks with Space and answers the checked in list order', () async {
      final term = FakeTerminal(width: 40, height: 10);
      final picked = Io.scope(() => Console.pickMany('Files', ['a', 'b', 'c']), terminal: term);
      await _pump();
      term.press(KeyPress.down);
      term.press(KeyPress.down);
      term.type(' ');
      term.press(KeyPress.up);
      term.press(KeyPress.up);
      term.type(' ');
      await _pump();
      expect(term.screen, contains('◉ a'));
      term.press(KeyPress.enter);
      expect(await picked, ['a', 'c']);
    });
  });

  group('drawing work without a terminal', () {
    test('a task ends in one line on stderr: ✓, ✖ or cancelled, and await gives what show gives', () async {
      final (out, err) = await _captured(() async {
        expect(await Task.run('t', (_) async => 4).show('Build', done: 'Built'), 4);
        await expectLater(
          Task.run('t', (_) => throw const FormatException('nope')).show('Pack'),
          throwsFormatException,
        );
        final task = Task.run('t', (_) => Future<void>.delayed(const Duration(seconds: 5)));
        task.cancel('user');
        await expectLater(task.show('Wait'), throwsA(isA<CancelledException>()));
      });
      expect(out, isEmpty, reason: 'everything an indicator draws goes to stderr (CLI-32)');
      final lines = err.trim().split('\n');
      expect(lines, hasLength(3), reason: err);
      expect(lines[0], matches(RegExp(r'^✓ Built \(\d+ms\)$')));
      expect(lines[1], startsWith('✖ Pack: FormatException: nope'));
      expect(lines[2], startsWith('⚠ Wait: cancelled'), reason: 'a cancel is not a ✓ (CON-5)');
    });

    test('a batch writes a line per ended item, each failure once, then its ending (CON-14)', () async {
      late Object error;
      final (_, err) = await _captured(() async {
        try {
          await _work(['a', 'b', 'c'], fail: {'b'}).show('Images');
        } catch (e) {
          error = e;
        }
      });
      expect(error, isA<BatchException<String, int>>());
      expect('bad b'.allMatches(err), hasLength(1), reason: err);
      expect(err, allOf(contains('✓ a'), contains('✓ c'), contains('⚠ Images: 1 of 3 failed')));
      expect(err.trim().split('\n').last, '⚠ Images: 1 of 3 failed');
    });

    test('a cancelled batch says how far it got (CON-5, CON-V11)', () async {
      final (_, err) = await _captured(() async {
        final batch = _work(List.generate(6, (i) => 'i$i'), gap: const Duration(milliseconds: 40));
        Timer(const Duration(milliseconds: 150), batch.cancel);
        await expectLater(batch.show('Images'), throwsA(isA<CancelledException>()));
      });
      expect(err, matches(RegExp(r'⚠ Images: cancelled after \d of 6')));
    });

    test('past a hundred items it writes a line per tenth, not per item', () async {
      final (_, err) = await _captured(() => List.generate(150, (i) => i).parallelize((i) => i).show('Many'));
      final lines = err.trim().split('\n');
      expect(lines.length, lessThan(15), reason: err);
      expect(lines.last, startsWith('✓ Many'));
      expect(err, contains('Many: 150/150 (100%)'));
    });

    test('progress draws and passes the batch on; its failures are said by its ending', () async {
      final (_, err) = await _captured(() async {
        final values = await _work(['a', 'bb'], fail: {'a'}).progress('Stage').values.toList();
        expect(values, [2]);
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      expect(err, contains('⚠ Stage: 1 of 2 failed'));
    });

    test('-q keeps warnings and failures, and drops what succeeded', () async {
      final (out, err) = await _captured(() async {
        await Task.run('t', (_) => 1).show('quiet');
        await _work(['a', 'b'], fail: {'b'}).show('Fetch').then((_) {}, onError: (Object _) {});
      }, level: LogLevel.warn);
      expect(out, isEmpty);
      expect(err, isNot(contains('quiet')));
      expect(err, allOf(contains('b: FormatException'), contains('Fetch: 1 of 2 failed')));
    });

    test('a warning is printed once, by the first display to hear it', () async {
      final (_, err) = await _captured(() async {
        final outer = Task.run('outer', (_) async {
          await Task.run('inner', (work) async => work.warn('slow mirror')).show('Inner');
        });
        await outer.show('Outer');
      });
      expect('slow mirror'.allMatches(err), hasLength(1), reason: err);
    });

    test('Console.bar ticks and closes with its summary; failures throw BatchException', () async {
      final (_, err) = await _captured(() async {
        final bar = Console.bar('Crawling', count: 3);
        bar.tick(label: 'one');
        bar.tick(label: 'two');
        bar.tally.add(Failed('three', const FormatException('lost'), StackTrace.empty));
        await expectLater(bar.close(), throwsA(isA<BatchException<Object?, Object?>>()));
        final ok = Console.bar('Fine');
        ok.tick();
        await ok.close();
        expect(() => ok.tick(), throwsStateError);
      });
      expect(
        err,
        allOf(contains('✓ one'), contains('three: FormatException: lost'), contains('⚠ Crawling: 1 of 3 failed')),
      );
      expect(err, contains('✓ Fine'));
      expect(() => Console.bar('x', count: -1), throwsArgumentError);
    });
  });

  group('drawing work on a terminal', () {
    test('drawing starts when show() is called, before any status (CON-7)', () async {
      final term = FakeTerminal(width: 60, height: 10);
      final gate = Completer<void>();
      final shown = Io.scope(() => Task.run('t', (_) => gate.future).show('Building'), terminal: term);
      await _pump();
      expect(term.screen, contains('Building'));
      gate.complete();
      await shown;
      expect(term.screen, matches(RegExp(r'^✓ Building \(\d+ms\)$')));
    });

    test('a batch is a header in items and a row per running item, label first (CON-V2, CON-V4)', () async {
      final term = FakeTerminal(width: 40, height: 12);
      final gate = Completer<void>();
      final batch = ['first.iso', 'second.iso'].parallelize(
        (name) => Task.run(name, (work) async {
          work.amount(512, total: 1024);
          await gate.future;
          return 1;
        }),
      );
      final shown = Io.scope(() => batch.show('Images'), terminal: term);
      await _pump(10);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final rows = term.screen.split('\n');
      expect(rows.first, contains('Images'));
      expect(rows.first, contains('0/2'), reason: 'the header counts items, never bytes');
      expect(rows[1], startsWith('  first.iso'));
      expect(rows[2], startsWith('  second.iso'));
      expect(rows[1], contains('50%'));
      gate.complete();
      await shown;
      expect(term.screen, matches(RegExp(r'^✓ Images \(\d+ms\)$')));
    });

    test('a running row is never evicted; the rest are +N more (CON-V3)', () async {
      final term = FakeTerminal(width: 40, height: 20);
      final gate = Completer<void>();
      final batch = List.generate(6, (i) => 'item$i').parallelize((name) => gate.future.then((_) => 1), concurrency: 6);
      final shown = Io.scope(
        () => Console.scope(() => batch.show('Many'), theme: const ConsoleTheme(rows: 3)),
        terminal: term,
      );
      await Future<void>.delayed(const Duration(milliseconds: 150));
      final screen = term.screen;
      expect(screen, contains('+3 more'), reason: screen);
      expect(screen.split('\n').where((r) => r.startsWith('  item')), hasLength(3));
      gate.complete();
      await shown;
    });

    test('durable lines land above the live region, which is redrawn under them', () async {
      final term = FakeTerminal(width: 50, height: 10);
      final gate = Completer<void>();
      final shown = Io.scope(() async {
        final task = Task.run('t', (_) => gate.future).show('Working');
        await _pump();
        Console.info('a log line');
        await _pump();
        expect(term.screen.split('\n'), [startsWith('ℹ a log line'), contains('Working')]);
        gate.complete();
        await task;
      }, terminal: term);
      await shown;
      expect(term.screen.split('\n').first, 'ℹ a log line');
    });

    test('a prompt suspends the region: nothing paints over it (CON-2)', () async {
      final term = FakeTerminal(width: 50, height: 10);
      final gate = Completer<void>();
      await Io.scope(() async {
        final work = Task.run('t', (_) => gate.future).show('Working');
        await _pump();
        final answer = Io.scope(() => Console.ask('Name'), stdin: Stream.value(utf8.encode('Ada\n')));
        expect(await answer, 'Ada');
        gate.complete();
        await work;
      }, terminal: term);
      expect(term.screen.split('\n'), ['Name:', startsWith('✓ Working')]);
      expect(term.writes.join(), isNot(contains('Name: \x1b')), reason: 'nothing painted after the question');
    });

    test('rows are measured after control characters are replaced (CON-4)', () async {
      final term = FakeTerminal(width: 30, height: 6);
      final gate = Completer<void>();
      final shown = Io.scope(
        () => Task.run('t', (_) => gate.future).show('tab\there and a long title that is cut'),
        terminal: term,
      );
      await _pump();
      final first = term.screen.split('\n').first;
      expect(first.length, lessThanOrEqualTo(29));
      expect(first, contains('tab here'));
      gate.complete();
      await shown;
    });

    test('a board taller than the terminal is cut to its height (X-12)', () async {
      final out = await _tty('''
        import 'dart:async';
        void main() async {
          final statuses = StreamController<int>();
          final shown = statuses.stream.parallelize((i) => Task.run('task \$i', (work) async {
            work.amount(512, total: 1024);
            await Future<void>.delayed(const Duration(seconds: 1));
          }), concurrency: 8).show('HEAD');
          for (var i = 0; i < 8; i++) {
            statuses.add(i);
            await Future<void>.delayed(const Duration(milliseconds: 40));
          }
          stderr.write('<end>');
          await statuses.close();
          await shown;
        }
      ''', rows: 6);
      final screen = FakeTerminal(width: 40, height: 6);
      screen.write(out.substring(0, out.indexOf('<end>')));
      expect(screen.screen.split('\n').first, contains('HEAD'), reason: screen.screen);
    }, testOn: 'mac-os || linux');

    test('NO_COLOR on a terminal still moves the cursor: frames are redrawn, not appended (CON-1)', () async {
      final out = await _tty(
        '''
        void main() async {
          await Task.run('t', (_) => Future<void>.delayed(const Duration(milliseconds: 400))).show('Spin');
        }
      ''',
        env: {'NO_COLOR': '1'},
      );
      expect(out, contains('\x1b[1A'), reason: 'each frame goes back over the last');
      expect(out, isNot(contains('\x1b[36m')), reason: 'and carries no colour');
      expect('Spin'.allMatches(out).length, greaterThan(1));
    }, testOn: 'mac-os || linux');
  });

  group('Tally', () {
    test('rates come from a sliding window, sampled on every tick, so a stall decays (CON-V1, CON-9)', () async {
      final clock = Clock.fake();
      await Clock.scope(() async {
        final tally = Tally(count: 1);
        tally.add(const Running('a', received: 0, total: 10000));
        for (var i = 1; i <= 5; i++) {
          await clock.advance(const Duration(milliseconds: 100));
          tally.add(Running('a', received: i * 1000, total: 10000));
        }
        expect(tally.rate, closeTo(10000, 1), reason: '1000 bytes a tenth of a second');
        expect(tally.items.single.rate, closeTo(10000, 1));
        expect(tally.eta, const Duration(milliseconds: 500));
        for (var i = 0; i < 12; i++) {
          await clock.advance(const Duration(milliseconds: 100));
          tally.sample();
        }
        expect(tally.rate, 0, reason: 'a stall decays to nothing');
      }, clock: clock);
    });

    test('the header rate is the sum of the items\', not a multiple (CON-V1)', () async {
      final clock = Clock.fake();
      await Clock.scope(() async {
        final tally = Tally(count: 4);
        for (var t = 0; t <= 10; t++) {
          if (t > 0) await clock.advance(const Duration(milliseconds: 100));
          for (final item in ['a', 'b', 'c', 'd']) {
            tally.add(Running(item, received: t * 1600, total: 64000));
          }
          tally.sample();
        }
        expect(tally.rate, closeTo(4 * 16000, 1000));
        expect(tally.total, 4 * 64000, reason: 'every item is sized');
      }, clock: clock);
    });

    test('a retry from zero counts its bytes once (CON-11); Done is all of it', () {
      final tally = Tally(count: 1);
      tally.add(const Running('a', received: 600, total: 1000));
      tally.add(const Running('a', received: 0, total: 1000));
      tally.add(const Running('a', received: 400, total: 1000));
      expect(tally.received, 400);
      tally.add(const Done('a', 1));
      expect(tally.received, 1000);
      expect(tally.done, 1);
      expect(tally.ended, 1);
    });

    test('two items with one label keep their own rates (CLI-3)', () {
      final tally = Tally();
      tally.add(const Running(1, label: 'same', received: 10, total: 100));
      tally.add(const Running(2, label: 'same', received: 90, total: 100));
      expect(tally.items, hasLength(2));
      expect([for (final i in tally.items) i.received], [10, 90]);
    });

    test('Tally.task and Tally.batch hear their work and end with it', () async {
      final task = Tally.task(Task.run('t', (w) async => w.amount(5, total: 10)));
      await task.over;
      expect(task.isTask, isTrue);
      expect(task.done, 1);
      final batch = Tally.batch(_work(['a', 'b'], fail: {'b'}));
      await batch.over;
      expect([batch.count, batch.done, batch.failed], [2, 1, 1]);
      expect(batch.failures.single.item, 'b');
      expect(batch.notes.single, isA<Failed<Object?, Object?>>());
      expect(() => batch.add(const Done('c', 1)), throwsStateError);
    });

    test('rows keep a running item\'s place and fill from those that ended', () {
      final tally = Tally();
      for (final i in ['a', 'b', 'c']) {
        tally.add(Running(i));
      }
      expect([for (final r in tally.rows(2).rows) r.item], ['a', 'b']);
      expect(tally.rows(2).more, 1);
      tally.add(const Done('a', 1));
      expect([for (final r in tally.rows(2).rows) r.item], ['c', 'b']);
      expect(tally.rows(2).more, 0);
      expect(() => tally.rows(0), throwsArgumentError);
    });
  });
}

/// What [source] writes to a [cols] × [rows] pseudo-terminal, escapes and all.
Future<String> _tty(String source, {int rows = 24, int cols = 40, Map<String, String> env = const {}}) async {
  final dir = tempDir('cli_tty_');
  final file = File('$dir/main.dart')
    ..writeAsStringSync("import 'dart:io';\nimport 'package:dart_toolkit/cli.dart';\n$source");
  final packages = File('.dart_tool/package_config.json').absolute.path;
  final command = 'stty rows $rows cols $cols; exec "${Platform.resolvedExecutable}" --packages=$packages ${file.path}';
  // TERM as a terminal emulator sets it: without it Dart reports no ANSI support.
  final child = await Process.start(
    'script',
    [
      if (Platform.isMacOS) ...['-q', '/dev/null', 'sh', '-c', command],
      if (!Platform.isMacOS) ...['-qec', command, '/dev/null'],
    ],
    environment: {'TERM': 'xterm-256color', 'LANG': 'en_US.UTF-8', ...env},
  );
  final text = StringBuffer();
  final read = child.stdout.transform(utf8.decoder).listen(text.write);
  await (read.asFuture<void>(), child.exitCode).wait.timeout(const Duration(seconds: 60));
  return '$text';
}

/// Runs [source] as a program of its own: what `Cli.run` does to the process cannot be watched
/// from inside the test runner.
Future<({int exitCode, String stdout, String stderr})> _script(String source) async {
  final process = await _start(source);
  final (out, err) = await (
    process.stdout.transform(utf8.decoder).join(),
    process.stderr.transform(utf8.decoder).join(),
  ).wait;
  return (exitCode: await process.exitCode, stdout: out, stderr: err);
}

Future<Process> _start(String source) async {
  final dir = tempDir('cli_script_');
  final file = File('$dir/main.dart')..writeAsStringSync("import 'package:dart_toolkit/cli.dart';\n$source");
  final packages = File('.dart_tool/package_config.json').absolute.path;
  return Process.start(Platform.resolvedExecutable, ['--packages=$packages', file.path]);
}
