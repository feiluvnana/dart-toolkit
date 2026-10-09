import 'dart:io';
import 'package:dart_toolkit/chrome.dart';
import 'framework.dart';

/// Opens a local page in headless Chrome and reads its rendered DOM.
class ChromeOpenBenchmark extends BenchmarkCase {
  ChromeOpenBenchmark() : super('chrome_open_html', module: 'chrome', throughputUnit: 'pages/s');

  late HttpServer _server;
  late Chrome _chrome;

  @override
  int get iterations => 10;

  @override
  int get warmupIterations => 2;

  @override
  Future<void> setup() async {
    _server = await HttpServer.bind('127.0.0.1', 0);
    _server.listen((req) {
      req.response
        ..headers.contentType = ContentType.html
        ..write('<html><body>${'<p>row</p>' * 500}</body></html>')
        ..close();
    });
    _chrome = await Chrome.launch();
  }

  @override
  Future<void> teardown() async {
    await _chrome.close();
    await _server.close(force: true);
  }

  @override
  Future<int> run(int count) async {
    final url = Uri.parse('http://127.0.0.1:${_server.port}/');
    for (var i = 0; i < count; i++) {
      final page = await _chrome.open(url);
      if (!(await page.html).text.contains('row')) throw StateError('empty page');
      await page.close();
    }
    return count;
  }
}

/// `eval` round trips on one open page.
class ChromeEvalBenchmark extends ChromeOpenBenchmark {
  @override
  String get name => 'chrome_eval_roundtrip';

  @override
  String get throughputUnit => 'evals/s';

  @override
  int get iterations => 200;

  @override
  Future<int> run(int count) async {
    final page = await _chrome.open(Uri.parse('http://127.0.0.1:${_server.port}/'));
    for (var i = 0; i < count; i++) {
      if (await page.eval<int>('1 + $i') != 1 + i) throw StateError('bad eval');
    }
    await page.close();
    return count;
  }
}

List<BenchmarkCase> createChromeBenchmarks() {
  final found =
      Env.has('DART_TOOLKIT_CHROME') ||
      [
        '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
        '/usr/bin/google-chrome',
        '/usr/bin/chromium',
        '/usr/bin/chromium-browser',
      ].any((p) => File(p).existsSync());
  return found ? [ChromeOpenBenchmark(), ChromeEvalBenchmark()] : [];
}
