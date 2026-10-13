import 'package:dart_toolkit/cli.dart';
import 'package:test/test.dart';

void main() {
  group('Command schema + handler + parse', () {
    test('typed Opt with default, reads and coerces', () async {
      final top = Opt<int>('top', 'N.', short: 'n', or: 10, parse: int.parse);
      int? seen;
      final cli = Command('app', 'X.', values: [top], handler: (ctx) => seen = ctx(top));
      expect(await cli.parse([]), 0);
      expect(seen, 10);
      expect(await cli.parse(['--top', '3']), 0);
      expect(seen, 3);
      expect(await cli.parse(['-n4']), 0);
      expect(seen, 4);
      expect(await cli.parse(['--top', 'soon']), 64);
    });

    test('Flag or:true reads --no-name', () async {
      final color = Flag('color', 'C.', or: true);
      var seen = -1;
      final cli = Command('app', 'X.', values: [color], handler: (ctx) => seen = ctx(color) ? 1 : 0);
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

    test('subcommands dispatch by name and alias; required many Arg', () async {
      final tag = Multi<String>('tag', 'A tag.', short: 't');
      final files = Arg<String>('files', 'Inputs.', many: true, required: true);
      var built = <String>[];
      List<String> tags = [];
      final cli = Command('tk', 'Tool.', commands: [
        Command('build', 'Builds.', aliases: ['b'], values: [tag, files], handler: (ctx) async {
          built = List.of(ctx(files));
          tags = List.of(ctx(tag));
        }),
      ]);
      expect(await cli.parse(['build', '--tag', 'a', 'f1', 'f2']), 0);
      expect(built, ['f1', 'f2']);
      expect(tags, ['a']);
      expect(await cli.parse(['b', 'f1']), 0);
      expect(built, ['f1']);
      expect(await cli.parse(['build']), 64);
    });

    test('--help is 0, unknown command is 64, UsageException is 64', () async {
      final cli = Command('tk', 'Tool.', commands: [
        Command('build', 'Builds.', handler: (_) {}),
      ]);
      expect(await cli.parse(['--help']), 0);
      expect(await cli.parse(['help', 'build']), 0);
      expect(await cli.parse(['rmove']), 64);
      final bad = Command('app', 'X.', handler: (_) => throw const UsageException('nope'));
      expect(await bad.parse([]), 64);
    });

    test('ctx on undeclared definition is StateError', () async {
      final top = Opt<int>('top', 'N.', or: 1);
      final other = Opt<int>('other', 'O.');
      var stateErr = false;
      final cli = Command('app', 'X.', values: [top], handler: (ctx) {
        try {
          ctx<int?>(other);
        } on StateError {
          stateErr = true;
        }
      });
      await cli.parse([]);
      expect(stateErr, isTrue);
    });

    test('schema validation is ArgumentError', () {
      expect(() => Flag('x', 'X.', short: 'xy'), throwsArgumentError);
      expect(() => Opt<String>('x', 'X.', required: true, or: 'd'), throwsArgumentError);
      expect(
        () => Command('c', 'C.', values: [Opt<String>('x', 'X.'), Opt<String>('x', 'Y.')]),
        throwsArgumentError,
      );
      expect(
        () => Command('c', 'C.', values: [Arg<String>('rest', 'R.', many: true), Arg<String>('id', 'I.')]),
        throwsArgumentError,
      );
    });
  });
}
