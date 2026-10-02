import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:dart_toolkit/tui.dart';
import 'package:test/test.dart';

void main() {
  group('HTTP discovery and symmetry', () {
    test('Http static verbs parse String or Uri', () {
      final req = Http.get('https://example.com/api');
      expect(req, isA<Fetch>());
    });

    test('Uri download method produces download stream', () {
      final url = 'https://example.com/file.txt'.url;
      final dl = url.download('test_out.txt');
      expect(dl, isA<Stream<BatchDownloadProgress>>());
    });
  });

  group('Doc facade', () {
    test('Doc shorthand and parse methods', () {
      final j = Doc.json('{"hello": "world"}');
      expect(j['hello'].to<String>(), 'world');

      final y = Doc.yaml('hello: world\nnumber: 42');
      expect(y['number'].to<int>(), 42);

      final t = Doc.toml('title = "TOML Example"');
      expect(t['title'].to<String>(), 'TOML Example');

      final ini = Doc.ini('[section]\nkey = val');
      expect(ini['section']['key'].to<String>(), 'val');
    });

    test('Doc.html and Doc.json answer CSS, XPath and JSONPath', () {
      final html = Doc.html('<div class="main"><a href="https://example.com/link">Test</a></div>');
      expect(html.$('.main a').text, 'Test');
      expect(html.$x('//a/text()').texts, ['Test']);
      expect(html.$x('//a').link?.toString(), 'https://example.com/link');

      final json = Doc.json('{"items": [{"name": "A"}, {"name": "B"}]}');
      expect(json.$(r'$.items[*].name').map((d) => d.to<String>()).toList(), ['A', 'B']);
    });

    test('Doc.read takes a Path', () async {
      await Path.tempDir((dir) async {
        final f = dir / 'test.yaml';
        await f.writeText('message: hello\ncount: 7\n');

        final doc = await Doc.read(f);
        expect(doc['message'].to<String>(), 'hello');
        expect(doc['count'].to<int>(), 7);
      });
    });
  });

  group('Fs facade', () {
    test('Fs properties and tempDir', () async {
      expect(Fs.current.existsSync(), isTrue);
      expect(Fs.home.existsSync(), isTrue);
      expect(Fs.temp.existsSync(), isTrue);

      final result = await Fs.tempDir((dir) async {
        final p = dir / 'created.txt';
        await p.writeText('ok');
        return p.existsSync();
      });
      expect(result, isTrue);
    });
  });

  group('Shell facade', () {
    test('Shell.pipe and which', () async {
      final pipe = Shell.pipe(['echo hi', 'cat']);
      expect(pipe, isA<CommandPipeline>());

      final dartPath = await Shell.which('dart');
      expect(dartPath, isNotNull);
    });
  });

  group('Hash enum usability', () {
    test('Hash.text, bytes, file and digest', () async {
      final hex = Hash.sha256.text('hello');
      expect(hex, '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824');

      final raw = Hash.sha256.digest([104, 101, 108, 108, 111]);
      expect(raw.length, 32);
      expect(raw.hex, hex);

      final bytesHex = Hash.sha256.bytes([104, 101, 108, 108, 111]);
      expect(bytesHex, hex);

      await Path.tempDir((dir) async {
        final f = dir / 'sample.txt';
        await f.writeText('hello');
        expect(await Hash.sha256.file(f), hex);
      });
    });
  });

  group('Sequence sorting thenByWith', () {
    test('thenByWith adds secondary comparator', () {
      final items = [(1, 'b'), (2, 'a'), (1, 'a')];
      final sorted = items.sequence.sortedBy((x) => x.$1).thenByWith((x, y) => x.$2.compareTo(y.$2)).toList();
      expect(sorted, [(1, 'a'), (1, 'b'), (2, 'a')]);
    });
  });

  group('Pool map with Iterable', () {
    test('Pool.map accepts Iterable', () async {
      final pool = await Pool.spawn(_EchoWorker.new, size: 2, isolate: false);
      addTearDown(pool.close);
      final results = await pool.map([1, 2, 3], ordered: true).toList();
      expect(results.rights, [1, 2, 3]);
    });
  });

  group('TuiTheme tokens', () {
    test('TuiTheme exposes border, borderStyle, frames, fill, empty, head', () {
      const theme = TuiTheme(
        border: Border.ascii,
        borderStyle: Style(bold: true),
        fill: '#',
        empty: '.',
        head: '>',
        frames: ['1', '2'],
      );
      expect(theme.border, Border.ascii);
      expect(theme.borderStyle, const Style(bold: true));
      expect(theme.fill, '#');
      expect(theme.empty, '.');
      expect(theme.head, '>');
      expect(theme.frames, ['1', '2']);
    });
  });

  group('Async parallelize', () {
    test('parallelize().unwrap() yields results in order', () async {
      final items = [1, 2, 3];
      final squares = await items.parallelize((x) => x * x, ordered: true).unwrap().toList();
      expect(squares, [1, 4, 9]);
    });
  });
}

final class _EchoWorker extends Worker<int, int> {
  @override
  int run(int item) => item;
}
