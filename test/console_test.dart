/// Tests for console output as a value rather than a side effect. Each group
/// names the behaviour that used to be untestable: `ConsoleWriter` took
/// injectable sinks, but everything else wrote straight to stdout, so a
/// progress bar, a spinner and every escape code were unreachable from a test.
library;

import 'dart:convert';
import 'dart:io';

import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:dart_toolkit/selector.dart';
import 'package:test/test.dart';

/// A writer over buffers, standing in for a terminal.
({ConsoleWriter writer, StringBuffer out, StringBuffer err}) _capture({
  bool tty = true,
  int? width,
}) {
  final out = StringBuffer();
  final err = StringBuffer();
  return (
    writer: ConsoleWriter(out: out, err: err, tty: tty, width: width),
    out: out,
    err: err,
  );
}

void main() {
  group('ConsoleWriter', () {
    test('a writer given a sink is not a terminal by default', () {
      // A buffer or a file wants text, not escape codes.
      expect(ConsoleWriter(out: StringBuffer()).tty, isFalse);
      expect(ConsoleWriter(out: StringBuffer(), tty: true).tty, isTrue);
    });

    test('geometry falls back when there is no terminal to ask', () {
      final writer = ConsoleWriter(out: StringBuffer());
      expect(writer.width, greaterThan(0));
      expect(writer.height, greaterThan(0));
    });

    test('an overridden width is what a rule measures', () {
      final probe = _capture(width: 20);
      probe.writer.rule();
      expect(Ansi.width(probe.out.toString().trim()), 20);
    });

    test('out and err stay apart', () {
      final probe = _capture();
      probe.writer
        ..writeln('to stdout')
        ..errorln('to stderr');

      expect(probe.out.toString(), 'to stdout\n');
      expect(probe.err.toString(), 'to stderr\n');
    });
  });

  group('Progress', () {
    test('draws into the writer it was given', () {
      final probe = _capture();
      Progress(total: 2, message: 'Fetching', writer: probe.writer)
        ..tick()
        ..done('Fetched');

      final text = Ansi.strip(probe.out.toString());
      expect(text, contains('Fetched'));
      expect(text, contains('2 / 2'));
      expect(text, contains('100.0%'));
    });

    test('draws nothing when the writer is not a terminal', () {
      final probe = _capture(tty: false);
      Progress(total: 2, writer: probe.writer)
        ..tick()
        ..done('Finished');

      // Not even a bare newline: a redirected run carries no marks at all.
      expect(probe.out.toString(), isEmpty);
    });

    test('a failure goes to the error sink', () {
      final probe = _capture();
      Progress(total: 2, writer: probe.writer).fail('Aborted');

      expect(Ansi.strip(probe.err.toString()), contains('Aborted'));
      expect(probe.out.toString(), isNot(contains('Aborted')));
    });

    test('bytes are reported as sizes', () {
      final probe = _capture();
      Progress(
        total: 2048,
        unit: ProgressUnit.bytes,
        writer: probe.writer,
      ).update(1024);

      expect(Ansi.strip(probe.out.toString()), contains('1.0 KB / 2.0 KB'));
    });
  });

  group('Spinner', () {
    test('resolves through the writer it was given', () {
      final probe = _capture();
      Spinner(writer: probe.writer)
        ..start('Resolving')
        ..ok('Resolved');

      expect(Ansi.strip(probe.out.toString()), contains('Resolved'));
    });

    test('a failure goes to the error sink', () {
      final probe = _capture();
      Spinner(writer: probe.writer)
        ..start('Resolving')
        ..fail('Gave up');

      expect(Ansi.strip(probe.err.toString()), contains('Gave up'));
    });

    test('logger.task takes the logger writer along', () async {
      final probe = _capture();
      final logger = ConsoleLogger(probe.writer);

      expect(await logger.task('Working', () async => 7), 7);
      // The spinner used to write to stdout however the logger was built.
      expect(Ansi.strip(probe.out.toString()), contains('Working'));
    });
  });

  group('Terminal and Cursor', () {
    test('control codes reach the writer', () {
      final probe = _capture();
      Terminal(probe.writer).clear();
      Cursor(probe.writer).up(3);

      expect(probe.out.toString(), '\x1B[2J\x1B[H\x1B[3A');
    });

    test('and are dropped when the writer is not a terminal', () {
      final probe = _capture(tty: false);
      Terminal(probe.writer).bell();
      Cursor(probe.writer).hide();

      expect(probe.out.toString(), isEmpty);
    });
  });

  group('ConsoleLogger', () {
    test('the writer can be replaced after the fact', () {
      final first = _capture();
      final second = _capture();
      final logger = ConsoleLogger(first.writer);

      logger.ok('one');
      logger.writer = second.writer;
      logger.ok('two');

      expect(Ansi.strip(first.out.toString()), contains('one'));
      expect(Ansi.strip(first.out.toString()), isNot(contains('two')));
      expect(Ansi.strip(second.out.toString()), contains('two'));
    });

    test('json writes one object per line, badges named not drawn', () {
      final probe = _capture();
      final logger = ConsoleLogger(probe.writer)..format = LogFormat.json;

      logger.ok('Done');
      logger.step(2, 5, 'Fetching');

      final lines = probe.out.toString().trim().split('\n');
      expect(lines, hasLength(2));

      final ok = jsonDecode(lines[0]) as Map<String, Object?>;
      expect(ok, {'level': 'ok', 'message': 'Done'});

      final step = jsonDecode(lines[1]) as Map<String, Object?>;
      expect(step['level'], 'step');
      expect(step['message'], 'Fetching');
      expect(step['step'], 2);
      expect(step['total'], 5);
    });

    test('json carries an error and its stack', () {
      final probe = _capture();
      final logger = ConsoleLogger(probe.writer)..format = LogFormat.json;

      logger.error('Failed', 'boom', StackTrace.current);

      final line = jsonDecode(probe.err.toString().trim()) as Map;
      expect(line['level'], 'error');
      expect(line['message'], 'Failed');
      expect(line['error'], 'boom');
      expect(line['stack'], isNotEmpty);
    });

    test('a stamp is a prefix in plain and a field in json', () {
      final plain = _capture();
      ConsoleLogger(plain.writer)
        ..stamp = true
        ..ok('Done');
      expect(
        Ansi.strip(plain.out.toString()),
        matches(RegExp(r'^\[\d{4}-\d{2}-\d{2}T')),
      );

      final json = _capture();
      ConsoleLogger(json.writer)
        ..stamp = true
        ..format = LogFormat.json
        ..ok('Done');
      expect(
        (jsonDecode(json.out.toString().trim()) as Map)['time'],
        isA<String>(),
      );
    });

    test('a file is just another sink', () async {
      final temp = Directory.systemTemp.createTempSync('dt_log_');
      addTearDown(() => temp.deleteSync(recursive: true));
      final path = '${temp.path}/run.log';
      final sink = File(path).openWrite();

      ConsoleLogger(ConsoleWriter(out: sink))
        ..format = LogFormat.json
        ..ok('Crawled 12 pages');
      await sink.close();

      final logged = jsonDecode(File(path).readAsStringSync().trim()) as Map;
      expect(logged['message'], 'Crawled 12 pages');
    });

    test('level still filters, whatever the format', () {
      final probe = _capture();
      ConsoleLogger(probe.writer)
        ..format = LogFormat.json
        ..level = LogLevel.warn
        ..info('quiet')
        ..warn('loud');

      final lines = probe.out.toString().trim().split('\n');
      expect(lines, hasLength(1));
      expect((jsonDecode(lines.single) as Map)['message'], 'loud');
    });
  });

  group('Ansi.wrap', () {
    test('breaks at spaces', () {
      expect(Ansi.wrap('the quick brown fox', 9), [
        'the quick',
        'brown fox',
      ]);
    });

    test('breaks inside a word too long to fit', () {
      expect(Ansi.wrap('supercalifragilistic', 8), [
        'supercal',
        'ifragili',
        'stic',
      ]);
    });

    test('keeps the newlines it was given', () {
      expect(Ansi.wrap('one\ntwo', 10), ['one', 'two']);
    });

    test('measures columns, not code units', () {
      // Three CJK characters are six columns, so a width of 4 takes two.
      expect(Ansi.wrap('日本語', 4), ['日本', '語']);
    });

    test('escape codes cost no width', () {
      final coloured = 'abc'.red();
      expect(Ansi.wrap(coloured, 3), [coloured]);
    });
  });

  group('Table', () {
    test('a cell with newlines becomes several lines in one row', () {
      final table = Table(headers: ['Key', 'Value'])
        ..add(['error', 'Connection reset\nRetried 3 times']);
      final lines = table.render().trimRight().split('\n');

      // Top rule, header, divider, two body lines, bottom rule.
      expect(lines, hasLength(6));
      expect(lines[3], contains('Connection reset'));
      expect(lines[4], contains('Retried 3 times'));
      // And it is still square.
      expect(lines.map(Ansi.width).toSet(), hasLength(1));
    });

    test('a width cap narrows the widest column and wraps it', () {
      final table = Table(
        headers: ['URL', 'N'],
        width: 30,
      )..add(['https://example.com/a/very/long/path', 1]);

      final lines = table.render().trimRight().split('\n');
      for (final line in lines) {
        expect(Ansi.width(line), lessThanOrEqualTo(30));
      }
      expect(lines.map(Ansi.width).toSet(), hasLength(1));
      // The long cell is still there, in pieces.
      expect(table.render(), contains('https:'));
      expect(table.render(), contains('path'));
    });

    test('a width cap wide enough changes nothing', () {
      final wide = Table(headers: ['a', 'b'], width: 200)..add([1, 2]);
      final bare = Table(headers: ['a', 'b'])..add([1, 2]);
      expect(wide.render(), bare.render());
    });

    test('an impossible width still renders a table', () {
      final table = Table(headers: ['a', 'b'], width: 4)..add([1, 2]);
      expect(table.render, returnsNormally);
      expect(table.render(), contains('1'));
    });

    test('wide characters still line up when wrapped', () {
      final table = Table(headers: ['名前'], width: 12)
        ..add(['日本語のテキスト']);
      final lines = table.render().trimRight().split('\n');
      expect(lines.map(Ansi.width).toSet(), hasLength(1));
    });
  });

  group('io.csv', () {
    test('format ends lines with the newline it was given', () {
      final rows = [
        {'a': '1', 'b': '2'},
      ];
      expect(io.csv.format(rows), 'a,b\n1,2\n');
      expect(io.csv.format(rows, newline: '\r\n'), 'a,b\r\n1,2\r\n');
    });

    test('a header-only render honours it too', () {
      expect(
        io.csv.format(const [], headers: ['a', 'b'], newline: '\r\n'),
        'a,b\r\n',
      );
    });

    test('write puts CRLF on disk', () async {
      final temp = Directory.systemTemp.createTempSync('dt_csv_');
      addTearDown(() => temp.deleteSync(recursive: true));
      final path = '${temp.path}/out.csv';

      await io.csv.write(path, [
        {'a': '1'},
      ], newline: '\r\n');

      expect(File(path).readAsStringSync(), 'a\r\n1\r\n');
      // And it reads back as one row, not two.
      expect(await io.csv.maps(path), [
        {'a': '1'},
      ]);
    });

    test('the four readers are typed, two eager and two streaming', () async {
      final temp = Directory.systemTemp.createTempSync('dt_csv_');
      addTearDown(() => temp.deleteSync(recursive: true));
      final path = '${temp.path}/in.csv';
      File(path).writeAsStringSync('a,b\n1,2\n');

      final List<Map<String, String>> maps = await io.csv.maps(path);
      final List<List<String>> matrix = await io.csv.matrix(path);
      final List<Map<String, String>> records =
          await io.csv.records(path).toList();
      final List<List<String>> rows = await io.csv.rows(path).toList();

      expect(maps, records);
      expect(matrix, rows);
    });
  });

  group('selector form values', () {
    test('a select reports the selected option', () {
      const html = '''
        <form>
          <select name="size">
            <option value="s">Small</option>
            <option value="m" selected>Medium</option>
          </select>
        </form>
      ''';
      // It used to read the select's own value attribute, which is never there.
      expect($(html).find('select').value, 'm');
    });

    test('a select with nothing selected reports its first option', () {
      const html = '<form><select><option value="a">A</option>'
          '<option value="b">B</option></select></form>';
      expect($(html).find('select').value, 'a');
    });

    test('an option with no value reports its text', () {
      const html = '<form><select><option selected>Plain</option>'
          '</select></form>';
      expect($(html).find('select').value, 'Plain');
    });

    test('a checkbox reports its value only when checked', () {
      const html = '''
        <form>
          <input type="checkbox" name="a" value="yes" checked>
          <input type="checkbox" name="b" value="no">
        </form>
      ''';
      final boxes = $(html).find('input');
      expect(boxes.value, 'yes');
      // An unticked box submits nothing, so it reads as absent.
      expect(boxes.values, ['yes']);
    });

    test('a ticked box with no value reports on, as HTML says', () {
      expect(
        $('<form><input type="checkbox" checked></form>').find('input').value,
        'on',
      );
    });

    test('a radio group reports the chosen one', () {
      const html = '''
        <form>
          <input type="radio" name="r" value="1">
          <input type="radio" name="r" value="2" checked>
        </form>
      ''';
      expect($(html).find('input').values, ['2']);
    });

    test('a textarea and a plain input are unchanged', () {
      expect(
        $('<form><textarea>hello</textarea></form>').find('textarea').value,
        'hello',
      );
      expect($('<form><input value="x"></form>').find('input').value, 'x');
    });

    test('lines decode entities', () {
      const html =
          '<main><div>Tom &amp; Jerry<br>caf&eacute;<br>&#65;&#66;</div></main>';
      // Stripping the tags left the entities behind in what is documented as
      // text.
      expect($(html, 'div').lines, ['Tom & Jerry', 'café', 'AB']);
    });

    test('lines without entities are untouched', () {
      expect($('<main><div>a<br>b</div></main>', 'div').lines, ['a', 'b']);
    });
  });

  group('cli', () {
    test('count reads a repeated switch as a level', () {
      final cli = Cli(const ['-vvv'])..flag('verbose', alias: 'v');
      expect(cli.count('verbose'), 3);
      expect(cli.has('verbose'), isTrue);
    });

    test('the long and short forms add up', () {
      final cli = Cli(const ['--verbose', '-v'])
        ..flag('verbose', alias: 'v');
      expect(cli.count('verbose'), 2);
    });

    test('a switch never given counts zero', () {
      final cli = Cli(const [])..flag('verbose', alias: 'v');
      expect(cli.count('verbose'), 0);
    });

    test('a flag reads its declared env variable', () {
      system.env.set('DT_CONSOLE_FORCE', 'yes');
      addTearDown(() => system.env.delete('DT_CONSOLE_FORCE'));

      // Only option() took an env before, so a boolean could not be set by
      // the shell.
      final cli = Cli(const [])..flag('force', env: 'DT_CONSOLE_FORCE');
      expect(cli.get('force', false), isTrue);
    });

    test('the command line still beats the flag env', () {
      system.env.set('DT_CONSOLE_FORCE', 'true');
      addTearDown(() => system.env.delete('DT_CONSOLE_FORCE'));

      final cli = Cli(const ['--no-force'])
        ..flag('force', env: 'DT_CONSOLE_FORCE');
      expect(cli.get('force', true), isFalse);
    });
  });

  group('zip', () {
    test('unpacking restores the execute bit and the modification time',
        () async {
      final root = Directory.systemTemp.createTempSync('dt_zip_mode_');
      addTearDown(() => root.deleteSync(recursive: true));

      final script = File('${root.path}/src/run.sh')
        ..createSync(recursive: true)
        ..writeAsStringSync('#!/bin/sh\necho hi\n');
      await system.run('chmod', ['755', script.path]);
      final when = DateTime(2021, 3, 4, 5, 6, 8);
      script.setLastModifiedSync(when);

      for (final name in ['out.zip', 'out.tar', 'out.tar.gz']) {
        final archive = '${root.path}/$name';
        await tool.zip.pack('${root.path}/src', archive);
        final dest = '${root.path}/back_$name';
        await tool.zip.unpack(archive, dest);

        final restored = File('$dest/run.sh');
        expect(restored.existsSync(), isTrue, reason: name);
        if (!Platform.isWindows) {
          // An archive of shell scripts used to unpack unrunnable.
          expect(
            restored.statSync().mode & 0x1ff,
            0x1ed,
            reason: '$name permissions',
          );
        }
        expect(restored.lastModifiedSync(), when, reason: '$name mtime');
      }
    });

    test('a plain file keeps its own mode', () async {
      final root = Directory.systemTemp.createTempSync('dt_zip_one_');
      addTearDown(() => root.deleteSync(recursive: true));

      final file = File('${root.path}/notes.txt')
        ..writeAsStringSync('hello');
      await system.run('chmod', ['600', file.path]);

      await tool.zip.pack(file.path, '${root.path}/one.zip');
      await tool.zip.unpack('${root.path}/one.zip', '${root.path}/back');

      if (!Platform.isWindows) {
        expect(
          File('${root.path}/back/notes.txt').statSync().mode & 0x1ff,
          0x180,
        );
      }
    });
  });

  group('git', () {
    test('fetch and checkout keep the soft-failure contract', () async {
      // Query methods promise a result rather than an exception, even with no
      // git and no repository.
      expect((await tool.git.fetch(remote: 'origin')).code, isA<int>());
      expect((await tool.git.checkout('nonexistent-branch-xyz')).ok, isFalse);
    });
  });

  group('concurrent', () {
    test('cancelling a pool stream launches nothing more', () async {
      var started = 0;
      final pool = Pool<int>(size: 1);
      final stream = pool.stream(List.generate(50, (i) => i), (i) async {
        started++;
        await Future<void>.delayed(const Duration(milliseconds: 1));
        return i;
      });

      final subscription = stream.listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await subscription.cancel();
      final atCancel = started;
      await Future<void>.delayed(const Duration(milliseconds: 60));

      // A task's body runs a turn after it is scheduled, so the one already
      // queued used to start its work after the cancel had landed.
      expect(started, atCancel);
    });
  });
}
