// The error contract, across modules: what each failure is, what its message says first, and
// what it keeps for whoever has to find the cause. CONVENTIONS.md §3 is the rule this pins.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_toolkit/archive.dart';
import 'package:dart_toolkit/async.dart';
import 'package:dart_toolkit/cli.dart';
import 'package:dart_toolkit/collection.dart';
import 'package:dart_toolkit/image.dart';
import 'package:dart_toolkit/process.dart';
import 'package:dart_toolkit/scrape.dart';
import 'package:dart_toolkit/xpath.dart';
import 'package:dart_toolkit/torrent.dart';
import 'package:test/test.dart' hide Retry;

import 'support.dart';

/// Throws an [E] whose message is [message] (a string or a matcher).
Matcher _message<E extends Object>(Object? message) => throwsA(isA<E>().having(_messageOf, 'message', message));

String? _messageOf(Object e) => switch (e) {
  MissingException(:final message) || FormatException(:final message) || FileSystemException(:final message) => message,
  TimeoutException(:final message) => message,
  _ => '$e',
};

void main() {
  group('a missing value is a MissingException: "Missing <what> [in <where>]"', () {
    final doc = '<p><a>x</a><b>y</b></p>'.html;
    final unset = 'DART_TOOLKIT_SURELY_UNSET_$pid';
    final cases = <String, (Object? Function(), String)>{
      'attr': (() => doc.$('a').first.attr('title'), 'Missing attribute "title" in <a>'),
      'link': (() => doc.$('b').first.link, 'Missing link (href, src or onclick) in <b>'),
      'imageLink': (() => doc.$('a').first.imageLink, 'Missing image link in <a>'),
      'rows': (() => doc.$('p').first.rows, 'Missing <table> in <p>'),
      'first of an empty selection': (() => doc.$('.none').first, 'Missing match for ".none"'),
      'last of an empty selection': (() => doc.$('.none').last, 'Missing match for ".none"'),
      'single of an empty selection': (() => doc.$('.none').single, 'Missing match for ".none"'),
      'a match past the end': (() => doc.$('a').at(3), 'Missing match 3 for "a" (1 matched)'),
      'first of an empty XPath selection': (() => doc.$x('//none').first, 'Missing match for "//none"'),
      'single of an empty XPath selection': (() => doc.$x('//none').single, 'Missing match for "//none"'),
      'an empty selection below a selection': (() => doc.$('p').$('.none').first, 'Missing match for ".none"'),
      'an image link on an empty selection': (() => doc.$('.none').imageLink, 'Missing image link in ".none"'),
      'an image link in a page with none': (() => doc.imageLink, 'Missing image link in the page'),
      'a JSON list that is not there': (() => '{"a": 1}'.json['items'].list, r'Missing $.items'),
      'a JSON map that is not there': (() => '{"a": 1}'.json['b'].map, r'Missing $.b'),
      'a JSON null': (() => '{"a": null}'.json['a'].to<int>(), r'Missing $.a'),
      'a JSONPath that selects nothing': (() => '{"a": 1}'.json.$(r'$.b').first, r'Missing $($.b)'),
      'an unset variable': (() => Env.get<String>(unset), 'Missing variable $unset in the environment'),
      'a blank cell': (
        () => Table.rows([
          {'n': ''},
        ]).rows.first.get<num>('n'),
        'Missing "n"',
      ),
      'a column the table does not have': (
        () => Table.rows([
          {'n': '1'},
        ]).rows.first.get<num>('m'),
        'Missing column "m"',
      ),
      'blank text read as a number': (() => '  '.to<int>(), 'Missing int in blank text'),
    };
    for (final MapEntry(key: what, value: (read, message)) in cases.entries) {
      test(what, () {
        expect(read, _message<MissingException>(message));
        expect((() => read()).orNull, isNull, reason: 'and orNull is its door');
      });
    }

    test('it keeps what was missing and where it was looked for', () async {
      expect(const MissingException('x').message, 'Missing x');
      expect(const MissingException('x').where, isNull);
      const column = MissingException('column "m"', where: 'sales.csv');
      expect((column.what, column.where, '$column'), ('column "m"', 'sales.csv', 'Missing column "m" in sales.csv'));

      final dir = tempDir('tk_missing');
      final csv = await Path('$dir/sales.csv').writeText('n\n1\n');
      final row = (await Table.read(csv)).rows.first;
      expect(
        () => row.get<num>('m'),
        throwsA(
          isA<MissingException>()
              .having((e) => e.what, 'what', 'column "m"')
              .having((e) => e.where, 'where', csv)
              .having((e) => e.message, 'message', 'Missing column "m" in $csv'),
        ),
      );
      await Path('$dir/src/a.txt').writeText('a');
      final zip = await Path('$dir/src').archive(to: '$dir/a.zip');
      await expectLater(
        (await Archive.read(zip)).entry('nope.txt'),
        throwsA(isA<MissingException>().having((e) => (e.what, e.where), 'what, where', ('entry nope.txt', zip))),
      );
      await expectLater(
        Shell.which('dart_toolkit_surely_not_a_command'),
        throwsA(
          isA<MissingException>().having((e) => '$e', 'text', 'Missing dart_toolkit_surely_not_a_command in PATH'),
        ),
      );
    });

    test('a download the server names no file for', () async {
      final (_, base) = await serve((r) => r.response.write('x'));
      final dir = tempDir('tk_noname');
      await expectLater(base.download(into: dir), _message<MissingException>('Missing file name in $base'));
    });
  });

  group('a value that is there but invalid is a FormatException: "Invalid <FORMAT> [in <file>][, line n]: <why>"', () {
    test('a cell', () {
      expect(
        () => Table.rows([
          {'n': 'x'},
        ]).rows.first.get<int>('n'),
        _message<FormatException>('Invalid value: "x" in "n", not an int'),
      );
      expect(
        () => Table.parse('k,v\n1,x\n', TableFormat.csv).rows.first.get<int>('v'),
        _message<FormatException>('Invalid CSV, line 2: "x" in "v", not an int'),
      );
    });
    test('a cell an aggregate reads', () {
      expect(
        () => Table.parse('k,v\n1,x\n', TableFormat.csv).groupBy(['k']).agg({'v': Agg.sum('v')}),
        _message<FormatException>('Invalid CSV, line 2: "x" in "v", not a num'),
      );
    });
    test('a cell in a file names the file and the line', () async {
      final csv = await Path('${tempDir('tk_cell')}/sales.csv').writeText('k,v\n1,x\n');
      final row = (await Table.read(csv)).rows.first;
      expect(() => row.get<int>('v'), _message<FormatException>('Invalid CSV in $csv, line 2: "x" in "v", not an int'));
    });
    test('a variable', () async {
      final name = 'DART_TOOLKIT_BAD_INT_$pid';
      await Env.scope(() {
        Env.set(name, 'abc');
        expect(() => Env.get<int>(name), _message<FormatException>('Invalid variable $name: "abc", expected int'));
      });
    });
    test('a JSON value', () {
      expect(
        () => '{"n": 1.7}'.json['n'].to<int>(),
        _message<FormatException>(r'Invalid JSON at $.n: a double, not an int'),
      );
    });
    test('a JSON list or map of the wrong kind names where', () {
      expect(
        () => '{"items": "x"}'.json['items'].list,
        _message<FormatException>(r'Invalid JSON at $.items: a String, not a list'),
      );
    });
  });

  group('the caller passed something invalid: an ArgumentError, never a silent 1', () {
    test('concurrency below 1', () async {
      Matcher bad(String name) => throwsA(
        isA<ArgumentError>()
            .having((e) => e.name, 'name', name)
            .having((e) => e.message, 'message', contains('expected at least 1')),
      );
      expect(() => [1].parallelize((i) => i, concurrency: 0), bad('concurrency'));
      expect(() => Stream.value(1).parallelize((i) => i, concurrency: -1), bad('concurrency'));
      expect(() => Pool<int, int>(_Twice.new, concurrency: 0), bad('concurrency'));
      expect(() => Semaphore(0), bad('permits'));
      expect(() => 'http://x/'.url.crawl<void>(concurrency: 0), bad('concurrency'));
      await expectLater(Http.scope(perHost: 0, () {}), bad('perHost'));
    });
  });

  group('a missing input is a PathNotFoundException from every module', () {
    final base = Path('${Directory.systemTemp.path}/tk_missing_input');
    final missing = Path('$base/nope.zip');
    final cases = <String, Future<Object?> Function()>{
      'hash a file': () => Hash.sha256.file(missing),
      'read an image': () => Image.read(missing),
      'read image info': () => ImageInfo.read(missing),
      'extract an archive': () => missing.unarchive(into: '$base/out'),
      'decompress a stream': () => Path('$base/nope.gz').unarchive(into: '$base/out'),
      'list an archive': () => Archive.read(missing),
      'archive a folder': () => base.archive(to: '${Directory.systemTemp.path}/tk_never.zip'),
      'read a torrent': () => Torrent.read(missing),
      'read a table': () => Table.read('$base/nope.csv'),
      'read a document': () => Doc.read('$base/nope.json'),
    };
    for (final MapEntry(key: what, value: run) in cases.entries) {
      test(what, () => expectLater(run(), throwsA(isA<PathNotFoundException>())));
    }
  });

  test("an archive's wrong or missing password is a PasswordException, a FormatException naming it", () async {
    final dir = tempDir('tk_password');
    await Path('$dir/src/a.txt').writeText('hello');
    for (final ext in ['zip', '7z']) {
      final archive = await Path('$dir/src').archive(to: '$dir/p.$ext', password: Secret('sesame'));
      await expectLater(
        archive.unarchive(into: '$dir/wrong_$ext', password: Secret('nope')),
        _message<PasswordException>(startsWith('Invalid archive in $archive: wrong password')),
      );
      await expectLater(
        archive.unarchive(into: '$dir/none_$ext'),
        _message<PasswordException>('Invalid archive in $archive: missing password'),
      );
    }
    final rar = Path('test/fixtures/crypted.rar').absolute;
    await expectLater(rar.unarchive(into: '$dir/r', password: Secret('x')), throwsA(isA<PasswordException>()));
    await expectLater(Archive.read('test/fixtures/encrypted_headers.rar'), throwsA(isA<PasswordException>()));
    expect(const PasswordException('x'), isA<FormatException>());
  });

  test('a file that will not parse is a FormatException naming it and the line, with a caret', () async {
    final dir = tempDir('tk_invalid');
    final cases = <String, (String, Future<Object?> Function(String path), String)>{
      'bad.json': ('{"a": 1,\n "b": }\n', Doc.read, 'Invalid JSON in'),
      'bad.yaml': ('a: 1\nb: [1, 2\n', Doc.read, 'Invalid YAML in'),
      'bad.toml': ('a = 1\nb = = 2\n', Doc.read, 'Invalid TOML in'),
      'bad.csv': ('a,b\n1,"2\n', Table.read, 'Invalid CSV in'),
      'bad.ndjson': ('{"a": 1}\n{x\n', Table.read, 'Invalid NDJSON in'),
    };
    for (final MapEntry(key: name, value: (text, read, kind)) in cases.entries) {
      final path = '$dir/$name';
      File(path).writeAsStringSync(text);
      await expectLater(
        read(path),
        throwsA(
          isA<FormatException>()
              .having((e) => e.message, 'message', startsWith('$kind $path, line 2: '))
              .having((e) => '$e', 'toString', contains('(at line 2,')),
        ),
        reason: name,
      );
    }
    expect(() => 'a = 1\nb = = 2\n'.toml, _message<FormatException>(startsWith('Invalid TOML, line 2: ')));
  });

  group('kinds', () {
    test('MissingException is an Exception, not an Error', () {
      expect(const MissingException('x'), isA<Exception>());
      expect(const MissingException('x'), isNot(isA<Error>()));
    });

    test('NativeException is "Cannot <op>: <native text>", keeping both', () {
      const e = NativeException('hash with sha256', 'boom');
      expect(e, isA<Exception>());
      expect((e.op, e.message), ('hash with sha256', 'boom'));
      expect('$e', 'Cannot hash with sha256: boom');
    });

    test('bytes that are not an image are a FormatException: bad input, not a bug', () async {
      await expectLater(
        Image.decode(Uint8List.fromList(List.filled(64, 7))),
        _message<FormatException>(startsWith('Invalid image: ')),
      );
      final junk = await Path('${tempDir('tk_junk')}/x.jpg').writeBytes(List.filled(64, 7));
      await expectLater(Image.read(junk), _message<FormatException>(startsWith('Invalid image in $junk: ')));
      await expectLater(ImageInfo.read(junk), _message<FormatException>(startsWith('Invalid image in $junk: ')));
    });

    test('String.to throws a FormatException naming the input, never MissingException', () {
      expect(() => 'abc'.to<int>(), _message<FormatException>('Invalid int: "abc"'));
      expect(() => 'abc'.to<double>(), _message<FormatException>('Invalid double: "abc"'));
    });

    test('malformed bencode and .torrent throw FormatException with byte offset', () {
      expect(
        () => Bencode.decode(Uint8List.fromList('i04e'.codeUnits)),
        throwsA(isA<FormatException>().having((e) => e.offset, 'offset', 0)),
      );
      expect(
        () => Torrent.decode('i42e'.codeUnits),
        _message<FormatException>('Invalid torrent: the root is not a dictionary'),
      );
      expect(
        () => Torrent.decode('i04e'.codeUnits),
        throwsA(
          isA<FormatException>()
              .having(
                (e) => e.message,
                'message',
                'Invalid torrent: bencode at offset 0: leading zero or negative zero',
              )
              .having((e) => e.offset, 'offset', 0),
        ),
        reason: 'one "Invalid", the torrent\'s',
      );
    });

    test('a bad magnet link is a FormatException naming the missing xt', () {
      expect(
        () => Torrent.parse('magnet:?dn=Test'),
        _message<FormatException>('Invalid magnet link: no xt=urn:btih: parameter'),
      );
    });

    test('a bad checksum is a ChecksumException, a FormatException naming the URL', () async {
      final (_, base) = await serve((r) => r.response.write('hello'));
      final url = base.resolve('a.txt');
      final wrong = '00' * 32;
      await expectLater(
        url.download(into: tempDir('tk_sum'), checksum: Checksum(Hash.sha256, wrong)),
        throwsA(
          isA<ChecksumException>()
              .having((e) => e, 'kind', isA<FormatException>())
              .having(
                (e) => e.message,
                'message',
                allOf(startsWith('Invalid checksum in $url: '), endsWith('expected $wrong')),
              ),
        ),
      );
    });
  });

  group('conflict: fail is a PathExistsException: "Cannot <verb> <source>: <target> exists"', () {
    late Path dir, a, b;
    setUp(() async {
      dir = tempDir('tk_conflict');
      a = await Path('$dir/src/a.txt').writeText('a');
      b = await Path('$dir/b.txt').writeText('b');
    });
    Matcher exists(String message, String target) =>
        throwsA(isA<PathExistsException>().having((e) => (e.message, e.path), 'message, path', (message, target)));

    test('a copy and a move', () async {
      await expectLater(b.copy(to: a, conflict: Conflict.fail), exists('Cannot copy $b: $a exists', a));
      await expectLater(b.move(to: a, conflict: Conflict.fail), exists('Cannot move $b: $a exists', a));
      expect(await b.readText(), 'b', reason: 'nothing moved');
    });

    test('a save', () async {
      final to = '$dir/t.csv';
      await File(to).writeAsString('x');
      await expectLater(
        Table.rows([
          {'a': 1},
        ]).save(to, conflict: Conflict.fail),
        exists('Cannot save Table: $to exists', to),
      );
    });

    test('an archive, either way', () async {
      final zip = await Path('$dir/src').archive(to: '$dir/a.zip');
      await expectLater(
        Path('$dir/src').archive(to: zip, conflict: Conflict.fail),
        exists('Cannot archive $dir/src: $zip exists', zip),
      );
      await zip.unarchive(into: '$dir/out');
      await expectLater(
        zip.unarchive(into: '$dir/out', conflict: Conflict.fail),
        exists('Cannot unarchive $zip: $dir/out/a.txt exists', '$dir/out/a.txt'),
      );
    });

    test('a download', () async {
      final (_, base) = await serve((r) => r.response.write('x'));
      final url = base.resolve('a.txt');
      final there = await Path('$dir/a.txt').writeText('old');
      await expectLater(
        url.download(into: dir, conflict: Conflict.fail),
        exists('Cannot download $url: $there exists', there),
      );
    });
  });

  group('a failure keeps what caused it', () {
    test('ClientException carries its cause and names it once', () async {
      const socket = SocketException('Connection refused');
      final e = ClientException('Could not connect', Uri.parse('http://x.test/'), socket);
      expect(e.cause, same(socket));
      expect('$e', contains('caused by: SocketException: Connection refused'));
      // a cause the message already quotes is not repeated
      expect(
        '${ClientException('Connection closed', null, const HttpException('Connection closed'))}',
        'Connection closed',
      );
      final refused = Uri.parse('http://127.0.0.1:1/');
      await expectLater(
        Http.scope(retry: Retry.none, () => refused.get()),
        throwsA(
          isA<ClientException>()
              .having((e) => e.uri, 'uri', refused)
              .having((e) => e.cause, 'cause', isA<SocketException>()),
        ),
      );
    });

    test("a hook that throws arrives as a Failed with the hook's own error and stack trace", () async {
      final (_, base) = await serve((r) => r.response.write('<p>hi</p>'));
      final statuses = await base.crawl<String>(onResponse: (ctx) => throw const FormatException('bad page')).settled;
      final failed = statuses.whereType<Failed<Uri, List<String>>>().single;
      expect(failed.error, isA<FormatException>());
      expect('${failed.stackTrace}', contains('errors_test.dart'), reason: 'the line that threw is findable');
    });

    test('a command that fails is a ShellException: "<command> exited <code>: <stderr tail>"', () async {
      await expectLater(
        Shell.sh('echo one >&2; echo oops >&2; exit 3'),
        throwsA(
          isA<ShellException>()
              .having((e) => e.result.exitCode, 'code', 3)
              .having((e) => '$e', 'text', endsWith(' exited 3: one\n  oops')),
        ),
      );
    }, testOn: '!windows');
  });

  group('several failures are one BatchException: "<n> of <m> failed: <first error>"', () {
    test('every failure with its item, every value in order', () async {
      final batch = [1, 2, 3].parallelize((i) => i == 2 ? throw const FormatException('two') : i);
      final caught = await batch.then<Object?>((_) => null, onError: (Object e) => e);
      expect(caught, isA<BatchException<int, int>>());
      final e = caught! as BatchException<int, int>;
      expect('$e', '1 of 3 failed: 2: FormatException: two');
      expect(e.failures.single.item, 2);
      expect(e.failures.single.error, isA<FormatException>());
      expect(e.values, [1, 3]);
      expect(e.count, 3);
    });

    test('a shown batch answers what await answers, and says it', () async {
      final err = StringBuffer();
      final shown = Io.scope(
        () => [1, 2, 3].parallelize((i) => i == 2 ? throw const FormatException('two') : i).show('Work'),
        stdout: StringBuffer(),
        stderr: err,
      );
      await expectLater(shown, throwsA(isA<BatchException<int, int>>()));
      expect(Style.plain('$err'), contains('Work: 1 of 3 failed'));
    });
  });

  group('a bug is never turned into a value: an Error in a batch is rethrown as it is', () {
    Future<(Object?, StackTrace?)> outcome(Future<Object?> future) =>
        future.then<(Object?, StackTrace?)>((_) => (null, null), onError: (Object e, StackTrace st) => (e, st));

    test('from a worker', () async {
      final boom = StateError('boom');
      final (error, stack) = await outcome([1, 2, 3].parallelize((i) => i == 2 ? throw boom : i));
      expect(error, same(boom));
      expect('$stack', contains('errors_test.dart'));
    });

    test('from a shown batch', () async {
      final boom = StateError('boom');
      final shown = Io.scope(
        () => [1, 2, 3].parallelize((i) => i == 2 ? throw boom : i).show('Work'),
        stdout: StringBuffer(),
        stderr: StringBuffer(),
      );
      expect((await outcome(shown)).$1, same(boom));
    });

    test("from a crawl's hook", () async {
      final (_, base) = await serve((r) => r.response.write('<p>hi</p>'));
      final boom = StateError('a bug in the hook');
      final (error, stack) = await outcome(base.crawl<String>(onResponse: (ctx) => throw boom));
      expect(error, same(boom));
      expect('$stack', contains('errors_test.dart'), reason: 'the line that threw is findable');
    });
  });

  group('a cancel is a CancelledException: "Cancelled: <reason>"', () {
    test('a scope', () async {
      final token = CancelToken();
      final done = Cancel.scope(() => 5.s.delay(), token: token);
      token.cancel('stop');
      await expectLater(
        done,
        throwsA(isA<CancelledException>().having((e) => (e.reason, '$e'), 'reason, text', ('stop', 'Cancelled: stop'))),
      );
    });

    test('a task', () async {
      final task = Task.run('job', (work) => 5.s.delay());
      task.cancel('user quit');
      await expectLater(task, throwsA(isA<CancelledException>().having((e) => '$e', 'text', 'Cancelled: user quit')));
    });
  });

  group('every timeout is a TimeoutException: "<subject> timed out after <d>"', () {
    test('a Cancel.scope deadline is a cancel and a timeout at once', () async {
      final caught = await Cancel.scope(
        () => 5.s.delay(),
        timeout: 20.ms,
      ).then<Object?>((_) => null, onError: (Object e) => e);
      expect(caught, isA<CancelledException>());
      expect(caught, isA<TimeoutException>());
      expect((caught! as TimeoutException).duration, 20.ms);
    });

    test('a plain cancel is not a timeout', () async {
      final token = CancelToken();
      final done = Cancel.scope(() => 5.s.delay(), token: token);
      token.cancel('stop');
      await expectLater(
        done,
        throwsA(isA<CancelledException>().having((e) => e, 'error', isNot(isA<TimeoutException>()))),
      );
    });

    test('an item of a batch', () async {
      final caught = await [
        'slow',
      ].parallelize((_) => 5.s.delay(), timeout: 20.ms).then<Object?>((_) => null, onError: (Object e) => e);
      expect(
        (caught! as BatchException).failures.single.error,
        isA<TimeoutException>().having((e) => e.message, 'message', 'slow timed out after 20ms'),
      );
    });

    test('a task', () async {
      final task = Task.run('job', (work) => 5.s.delay());
      addTearDown(task.cancel);
      await expectLater(task.timeout(20.ms), _message<TimeoutException>('job timed out after 20ms'));
    });

    test('a command', () async {
      await expectLater(
        Shell.run('sleep 5', timeout: 100.ms),
        _message<TimeoutException>('sleep 5 timed out after 100ms'),
      );
    }, testOn: '!windows');

    test('a request', () async {
      final (_, base) = await serve((r) => 2.s.delay());
      await expectLater(
        Http.scope(timeout: 100.ms, retry: Retry.none, () => base.get()),
        _message<TimeoutException>('$base timed out after 100ms'),
      );
    });
  });

  group('retry never repeats what would fail the same way', () {
    Future<int> attempts(Object error) async {
      var n = 0;
      try {
        await const Retry(2, backoff: Duration.zero).run(() {
          n++;
          throw error;
        });
      } catch (_) {} // the throw is the point; the count is the answer
      return n;
    }

    test('a bug, bad input, an absence or a cancel is tried once', () async {
      expect(await attempts(StateError('bug')), 1);
      expect(await attempts(const FormatException('bad')), 1);
      expect(await attempts(const MissingException('x')), 1);
      expect(await attempts(const CancelledException()), 1);
    });

    test('a transient failure is retried', () async {
      expect(await attempts(const SocketException('reset')), 3);
      expect(await attempts(TimeoutException('slow')), 3);
    });

    test('a command that cannot run (exit 127) is tried once', () async {
      var n = 0;
      await expectLater(
        const Retry(2, backoff: Duration.zero).run(() {
          n++;
          return Shell.run('dart_toolkit_surely_not_a_command').text;
        }),
        throwsA(isA<ShellException>().having((e) => e.result.exitCode, 'code', 127)),
      );
      expect(n, 1);
    }, testOn: '!windows');

    test('an explicit when: still decides', () async {
      var n = 0;
      await expectLater(
        Retry(2, backoff: Duration.zero, when: (_) => true).run(() {
          n++;
          throw const FormatException('bad');
        }),
        throwsFormatException,
      );
      expect(n, 3);
    });
  });
}

final class _Twice extends Worker<int, int> {
  @override
  int run(int item, Work work) => item * 2;
}
