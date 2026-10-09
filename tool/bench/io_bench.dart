import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:dart_toolkit/archive.dart';
import 'package:dart_toolkit/cli.dart';
import 'package:dart_toolkit/scrape.dart';
import 'framework.dart';

/// Random bytes that do not compress, so a codec is measured on its worst case.
Uint8List _noise(int size, [int seed = 1]) {
  final rnd = Random(seed);
  final out = Uint8List(size);
  for (var i = 0; i < size; i++) {
    out[i] = rnd.nextInt(256);
  }
  return out;
}

/// Zips one 32 MiB file and 1000 small ones, then extracts the archive; the reference is the
/// `zip`/`unzip` CLIs when they are on the PATH.
class ArchiveZipBenchmark extends BenchmarkCase {
  ArchiveZipBenchmark() : super('archive_zip_roundtrip', module: 'archive', throughputUnit: 'MB/s');

  late Directory _dir;
  int _bytes = 0;
  bool _hasCli = false;

  @override
  int get iterations => 3;

  @override
  int get warmupIterations => 1;

  @override
  Future<void> setup() async {
    _dir = Directory.systemTemp.createTempSync('bench_zip_');
    final src = Directory('${_dir.path}/src/small')..createSync(recursive: true);
    File('${_dir.path}/src/big.bin').writeAsBytesSync(_noise(32 << 20));
    for (var i = 0; i < 1000; i++) {
      File('${src.path}/$i.txt').writeAsStringSync('line $i\n' * 20);
    }
    _bytes = (32 << 20) + 1000 * ('line 0\n' * 20).length;
    _hasCli = Process.runSync('which', ['zip']).exitCode == 0 && Process.runSync('which', ['unzip']).exitCode == 0;
  }

  @override
  Future<void> teardown() async => _dir.deleteSync(recursive: true);

  @override
  Future<int> run(int count) async {
    for (var i = 0; i < count; i++) {
      final zip = '${_dir.path}/out$i.zip', out = '${_dir.path}/x$i';
      await Path('${_dir.path}/src').archive(to: zip);
      await Path(zip).unarchive(into: out);
      File(zip).deleteSync();
      Directory(out).deleteSync(recursive: true);
    }
    return _bytes * count;
  }

  @override
  Future<int>? runReference(int count) {
    if (!_hasCli) return null;
    return () async {
      for (var i = 0; i < count; i++) {
        final zip = '${_dir.path}/ref$i.zip', out = '${_dir.path}/r$i';
        Process.runSync('zip', ['-qr', zip, 'src'], workingDirectory: _dir.path);
        Process.runSync('unzip', ['-q', zip, '-d', out]);
        File(zip).deleteSync();
        Directory(out).deleteSync(recursive: true);
      }
      return _bytes * count;
    }();
  }
}

/// Downloads a 64 MiB body from a local server; the reference streams it with a raw
/// `HttpClient` into a file.
class DownloadBenchmark extends BenchmarkCase {
  DownloadBenchmark() : super('http_download_64mb', module: 'http', throughputUnit: 'MB/s');

  static const _size = 64 << 20;
  late HttpServer _server;
  late Directory _dir;
  late Uint8List _body;

  @override
  int get iterations => 3;

  @override
  int get warmupIterations => 1;

  @override
  Future<void> setup() async {
    _dir = Directory.systemTemp.createTempSync('bench_dl_');
    _body = _noise(_size);
    _server = await HttpServer.bind('127.0.0.1', 0);
    _server.listen((req) {
      req.response
        ..headers.contentLength = _size
        ..add(_body)
        ..close();
    });
  }

  @override
  Future<void> teardown() async {
    await _server.close(force: true);
    _dir.deleteSync(recursive: true);
  }

  Uri get _url => Uri.parse('http://127.0.0.1:${_server.port}/blob.bin');

  @override
  Future<int> run(int count) async {
    for (var i = 0; i < count; i++) {
      final to = Path('${_dir.path}/a$i.bin');
      await _url.download(to: to, conflict: Conflict.overwrite);
      await to.delete();
    }
    return _size * count;
  }

  @override
  Future<int>? runReference(int count) async {
    final client = HttpClient();
    try {
      for (var i = 0; i < count; i++) {
        final file = File('${_dir.path}/r$i.bin');
        final res = await (await client.getUrl(_url)).close();
        await res.pipe(file.openWrite());
        file.deleteSync();
      }
    } finally {
      client.close(force: true);
    }
    return _size * count;
  }
}

/// Crawls 300 linked pages on a local server at [concurrency]; no reference.
class CrawlBenchmark extends BenchmarkCase {
  CrawlBenchmark(this.concurrency)
    : super('scrape_crawl_300_c$concurrency', module: 'scrape', throughputUnit: 'pages/s');

  final int concurrency;
  static const _pages = 300;
  late HttpServer _server;

  @override
  int get iterations => 2;

  @override
  int get warmupIterations => 1;

  @override
  Future<void> setup() async {
    _server = await HttpServer.bind('127.0.0.1', 0);
    _server.listen((req) {
      final n = int.tryParse(req.uri.path.substring(1)) ?? 0;
      final links = [
        for (var k = 1; k <= 5; k++)
          if (n + k < _pages) '<a href="/${n + k}">${n + k}</a>',
      ].join();
      req.response
        ..headers.contentType = ContentType.html
        ..write('<html><body><h1>page $n</h1>$links</body></html>')
        ..close();
    });
  }

  @override
  Future<void> teardown() => _server.close(force: true);

  @override
  Future<int> run(int count) async {
    var pages = 0;
    for (var i = 0; i < count; i++) {
      final seed = Uri.parse('http://127.0.0.1:${_server.port}/0');
      pages += await Http.scope(
        perHost: concurrency,
        () => seed
            .crawl<int>(
              concurrency: concurrency,
              onResponse: (ctx) {
                ctx.emit(1);
                ctx.html.$('a').links.forEach(ctx.follow);
              },
            )
            .items
            .length,
      );
    }
    if (pages != _pages * count) throw StateError('crawled $pages of ${_pages * count} pages');
    return pages;
  }
}

/// Writes 100k `Console.info` lines to stdout (a pipe under the runner); the reference is
/// `stdout.writeln` of the same text.
class ConsoleLogBenchmark extends BenchmarkCase {
  ConsoleLogBenchmark() : super('cli_console_info_100k', module: 'cli', throughputUnit: 'lines/s');

  static const _lines = 100000;

  @override
  int get iterations => 1;

  @override
  int get warmupIterations => 0;

  @override
  Future<int> run(int count) async {
    for (var i = 0; i < _lines * count; i++) {
      Console.info('line $i');
    }
    await stdout.flush();
    return _lines * count;
  }

  @override
  Future<int>? runReference(int count) async {
    for (var i = 0; i < _lines * count; i++) {
      stdout.writeln('  ℹ line $i');
    }
    await stdout.flush();
    return _lines * count;
  }
}

List<BenchmarkCase> createIoBenchmarks() => [
  ArchiveZipBenchmark(),
  DownloadBenchmark(),
  CrawlBenchmark(1),
  CrawlBenchmark(16),
  ConsoleLogBenchmark(),
];
