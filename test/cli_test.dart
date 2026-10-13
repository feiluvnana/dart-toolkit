import 'package:dart_toolkit/cli.dart';
import 'package:test/test.dart';

void main() {
  group('Args.flag', () {
    test('long, short and grouped shorts', () {
      expect(Cli.parse(['--verbose']).flag('verbose'), isTrue);
      expect(Cli.parse(['-v']).flag('verbose', short: 'v'), isTrue);
      final args = Cli.parse(['-vq']);
      expect(args.flag('verbose', short: 'v'), isTrue);
      expect(args.flag('quiet', short: 'q'), isTrue);
    });

    test('absent is false', () {
      expect(Cli.parse([]).flag('verbose'), isFalse);
    });

    test('same name again returns the same answer', () {
      final args = Cli.parse(['--verbose']);
      expect(args.flag('verbose'), isTrue);
      expect(args.flag('verbose'), isTrue);
    });
  });

  group('Args.option', () {
    test('--out x, --out=x and -o x', () {
      expect(Cli.parse(['--out', 'x']).option('out'), 'x');
      expect(Cli.parse(['--out=x']).option('out'), 'x');
      expect(Cli.parse(['-o', 'x']).option('out', short: 'o'), 'x');
    });

    test('last value wins, absent is null', () {
      expect(
        Cli.parse(['--out', 'a', '--out', 'b']).option('out'),
        'b',
      );
      expect(Cli.parse([]).option('out'), isNull);
    });

    test('the next token is the value even when it starts with -', () {
      expect(
        Cli.parse(['--out', '--verbose']).option('out'),
        '--verbose',
      );
    });

    test('a missing value is a FormatException', () {
      expect(
        () => Cli.parse(['--out']).option('out'),
        throwsA(isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('--out needs a value'),
        )),
      );
    });
  });

  group('Args.multi', () {
    test('collects every value in order', () {
      final args = Cli.parse(['-H', 'a', '--header', 'b', '--header=c']);
      expect(args.multi('header', short: 'H'), ['a', 'b', 'c']);
    });

    test('absent is empty', () {
      expect(Cli.parse([]).multi('header'), isEmpty);
    });
  });

  group('Args.rest', () {
    test('returns positionals', () {
      final args = Cli.parse(['--verbose', 'get', 'u']);
      args.flag('verbose');
      expect(args.rest(), ['get', 'u']);
    });

    test('-- ends option parsing', () {
      final args = Cli.parse(['--', '--verbose']);
      expect(args.rest(), ['--verbose']);
    });

    test('a leftover option is a FormatException naming it', () {
      final args = Cli.parse(['--bogus']);
      expect(
        () => args.rest(),
        throwsA(isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('--bogus'),
        )),
      );
    });

    test('declaring after rest is a StateError', () {
      final args = Cli.parse(['x']);
      args.rest();
      expect(() => args.flag('verbose'), throwsStateError);
    });

    test('subcommands as patterns', () {
      final args = Cli.parse(['get', 'http://e.com']);
      switch (args.rest()) {
        case ['get', final url]:
          expect(url, 'http://e.com');
        default:
          fail('wrong branch');
      }
    });
  });

  group('Args.usage', () {
    test('lists declarations in call order, aligned', () {
      final args = Cli.parse([]);
      args.flag('verbose', short: 'v', help: 'Talk a lot.');
      args.option('out', short: 'o', help: 'Output folder.');
      final usage = args.usage();
      expect(usage, contains('-v, --verbose'));
      expect(usage, contains('-o, --out <value>'));
      expect(usage, contains('Output folder.'));
    });
  });
}
