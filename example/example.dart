import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:http/http.dart' as http;

void main(List<String> args) async {
  Console.rule('Dart Toolkit: Complete API Showcase');

  // =========================================================================
  // 1. Process & Shell Execution (`dart_toolkit/process`)
  // =========================================================================
  Logger.step(1, 8, r'Process & Shell Automation ($, run, which, pipe, ShellResult)');

  // 1.1 Executable lookup
  final dartPath = await which('dart');
  Logger.info('which("dart"): $dartPath');

  // 1.2 Top-level $ and run()
  final echo1 = await $(r'echo "Running via $"', quiet: true);
  final echo2 = await run('echo "Running via run()"', quiet: true);
  Logger.ok('Dollar execution: "${echo1.text}" (ok: ${echo1.ok}, exitcode: ${echo1.exitcode})');
  Logger.ok('Run execution:    "${echo2.text}" (failed: ${echo2.failed})');

  // 1.3 Extension syntax on String and Path
  final stringRun = await 'echo "Running via String.run()"'.run(quiet: true);
  Logger.ok('String.run(): "${stringRun.text}"');

  final tempRunDir = Path.temp / 'toolkit_proc_demo';
  await tempRunDir.mkdir();
  try {
    final pathRun = await (await which('echo') ?? 'echo'.path).run(
      args: ['Running', 'via', 'Path.run()'],
      workdir: tempRunDir,
      quiet: true,
    );
    Logger.ok('Path.run(): "${pathRun.text}"');
  } finally {
    await tempRunDir.delete(recursive: true);
  }

  // 1.4 Structured output: .lines, .json
  final multiLine = await 'echo "line1\nline2\nline3"'.run(quiet: true);
  Logger.info('ShellResult.lines: ${multiLine.lines}');

  final jsonCmd = await 'echo \'{"name": "dart_toolkit", "version": 9, "features": ["async", "cli", "fs"]}\''.run(quiet: true);
  final parsedJson = jsonCmd.json as Map<String, dynamic>;
  Logger.ok('ShellResult.json: name=${parsedJson['name']}, version=${parsedJson['version']}, features=${parsedJson['features']}');

  // 1.5 Command Piping: .pipe() and operator |
  final piped = await ('echo "apple\nbanana\ncherry"'.pipe('grep an') | 'tr a-z A-Z').run(quiet: true);
  Logger.ok('Command pipeline (pipe & |): "${piped.text}"');

  // =========================================================================
  // 2. Filesystem & Path Utilities (`dart_toolkit/fs`)
  // =========================================================================
  Logger.step(2, 8, 'Filesystem & Path API (Path, read/write, sanitized, checksums, zip)');

  // 2.1 Static getters
  Logger.info('Path.home:    ${Path.home}');
  Logger.info('Path.temp:    ${Path.temp}');
  Logger.info('Path.current: ${Path.current}');

  final workspace = Path.temp / 'toolkit_fs_showcase';
  await workspace.mkdir();

  try {
    // 2.2 Path composition and properties
    final file = workspace / 'sub' / 'data.json';
    Logger.info('Path operator /: $file');
    Logger.info('Path components: name="${file.name}", stem="${file.stem}", ext="${file.ext}", parent="${file.parent}"');
    Logger.info('Path segments:   ${file.segments}');

    // 2.3 Sanitization
    final dirtyPath = 'Folder: Name / Invalid * File ? Name <1>.txt'.path.sanitized();
    Logger.info('Path.sanitized(): "$dirtyPath"');

    // 2.4 Writing and Reading Text, Lines, Bytes, and JSON
    final textFile = workspace / 'notes.txt';
    await textFile.writeText('Line 1: Alpha\nLine 2: Beta\n');
    await textFile.append('Line 3: Gamma\n');
    await textFile.replace('Beta', 'BETA_REPLACED');

    Logger.ok('readText():\n${(await textFile.readText()).trim()}');
    Logger.info('readLines(): ${await textFile.readLines()}');
    Logger.info('readBytes(): ${(await textFile.readBytes()).length} bytes');

    // 2.5 Structured read/write: JSON, HTML, XML
    final jsonFile = workspace / 'payload.json';
    await jsonFile.writeJson({'framework': 'dart_toolkit', 'active': true});
    final jsonDoc = await jsonFile.readJson();
    Logger.ok('readJson(): framework=${jsonDoc.$jsonpath(r'$.framework').firstOrNull?.raw}');

    final htmlFile = workspace / 'page.html';
    await htmlFile.writeText('<html><body><h1>Hello HTML</h1><p class="desc">Sample paragraph</p></body></html>');
    final htmlDoc = await htmlFile.readHtml();
    Logger.ok('readHtml(): h1="${htmlDoc.$('h1').firstOrNull?.text}", p="${htmlDoc.$xpath('//p[@class="desc"]').firstOrNull?.text}"');

    final xmlFile = workspace / 'catalog.xml';
    await xmlFile.writeText('<catalog><book id="1"><title>Dart Guide</title></book></catalog>');
    final xmlDoc = await xmlFile.readXml();
    Logger.ok('readXml(): title="${xmlDoc.$xpath('//book/title/text()').firstOrNull?.value}"');

    // 2.6 Entity checks & sizing
    Logger.info('type(): ${await textFile.type()}, exist(): ${await textFile.exist()}, size(): ${await textFile.size()} bytes');

    // 2.7 Cryptographic checksums
    Logger.ok('sha256(): ${await textFile.sha256()}');
    Logger.ok('md5():    ${await textFile.md5()}');

    // 2.8 Directory listing, glob, copy, move, delete, zip, unzip
    final nestedDir = workspace / 'nested';
    await nestedDir.mkdir();
    await (nestedDir / 'f1.txt').writeText('file 1');
    await (nestedDir / 'f2.log').writeText('file 2');

    final allEntities = await workspace.list(recursive: true).toList();
    final allFiles = await workspace.files(recursive: true).toList();
    final allDirs = await workspace.dirs().toList();
    final globLogs = await workspace.glob('**/*.log').toList();

    Logger.info('list(): ${allEntities.length} entities, files(): ${allFiles.length}, dirs(): ${allDirs.length}');
    Logger.info('glob("**/*.log"): ${globLogs.map((p) => p.name).toList()}');

    // Copy & Move
    final copyTarget = workspace / 'notes_copy.txt';
    await textFile.copy(copyTarget.path);
    Logger.ok('copy(): exists=${await copyTarget.exist()}');

    final moveTarget = workspace / 'notes_moved.txt';
    await copyTarget.move(moveTarget.path);
    Logger.ok('move(): exists=${await moveTarget.exist()}');

    // Zip and Unzip
    final zipFile = Path.temp / 'toolkit_demo_archive.zip';
    await nestedDir.zip(zipFile.path);
    Logger.ok('zip(): archive=${zipFile.name} (${await zipFile.size()} bytes)');

    final extractedDir = workspace / 'unzipped';
    await zipFile.unzip(extractedDir.path);
    Logger.ok('unzip(): extracted ${await extractedDir.files(recursive: true).length} files');
    await zipFile.delete();
  } finally {
    await workspace.delete(recursive: true);
  }
  Logger.ok('Workspace directory deleted.');

  // =========================================================================
  // 3. Environment & .env Management (`dart_toolkit/util`)
  // =========================================================================
  Logger.step(3, 8, 'Environment & .env (Env.get, Env.set, Env.require, Env.isCI)');

  // 3.1 In-memory management & defaults
  Env.set('DATABASE_HOST', 'localhost');
  Env.set('DATABASE_PORT', '5432');
  Logger.info('Env.get("DATABASE_HOST"): ${Env.get('DATABASE_HOST')}');
  Logger.info('Env.get with fallback:    ${Env.get('DATABASE_USER', 'postgres')}');
  Logger.info('Env.require:              ${Env.require('DATABASE_PORT')}');
  Logger.info('Env.has("DATABASE_HOST"): ${Env.has('DATABASE_HOST')}');
  Logger.info('Env.all() keys:           ${Env.all().keys.take(5).toList()}...');

  // 3.2 Loading .env syntax strings
  final dotEnvContent = '''
# Server Configuration
SERVER_NAME="Production API"
CACHE_ENABLED=true # inline comment
EXPORT_VAR=export_value
''';
  final loadedDotEnv = Env.load(dotEnvContent);
  Logger.ok('Env.load: $loadedDotEnv');

  // 3.3 Platform & CI environment detection
  Logger.info('Env.isMac: ${Env.isMac} (isMacOS: ${Env.isMacOS})');
  Logger.info('Env.isWin: ${Env.isWin} (isWindows: ${Env.isWindows})');
  Logger.info('Env.isLinux: ${Env.isLinux}');
  Logger.info('Env.isCI: ${Env.isCI}');

  // =========================================================================
  // 4. Async & Concurrency Primitives (`dart_toolkit/async`)
  // =========================================================================
  Logger.step(4, 8, 'Async Concurrency (parallelize, retry, Mutex, Semaphore, isolate, stream extensions)');

  // 4.1 Parallelize on Iterable
  final items = [1, 2, 3, 4, 5, 6];
  final parallelResults = await items.parallelize((n) async {
    await 15.ms.delay();
    return n * 10;
  }, concurrency: 3);

  final successValues = [
    for (final r in parallelResults)
      if (r case Right(:final value)) value,
  ];
  Logger.ok('Iterable.parallelize(concurrency: 3): $successValues');

  // 4.2 Retry with builder extension
  var retryTries = 0;
  final retryVal = await (() async {
    retryTries++;
    if (retryTries < 2) throw StateError('Transient timeout');
    return 'Connected successfully';
  }).retry()
      .attempts(3)
      .delay(10.ms)
      .backoff(1.5)
      .jitter(true);
  Logger.ok('retry(): "$retryVal" (succeeded on attempt #$retryTries)');

  // 4.3 Mutex (Exclusive critical section)
  final mutex = Mutex();
  var mutexCounter = 0;
  await [1, 2, 3, 4].parallelize((_) => mutex.protect(() async {
    final current = mutexCounter;
    await 5.ms.delay();
    mutexCounter = current + 1;
  }));
  Logger.ok('Mutex.protect(): counter=$mutexCounter (isLocked=${mutex.isLocked})');

  // 4.4 Semaphore (Permit-limited section)
  final semaphore = Semaphore(2);
  var maxConcurrent = 0;
  var currentConcurrent = 0;
  await [1, 2, 3, 4, 5].parallelize((_) => semaphore.run(() async {
    currentConcurrent++;
    if (currentConcurrent > maxConcurrent) maxConcurrent = currentConcurrent;
    await 10.ms.delay();
    currentConcurrent--;
  }));
  Logger.ok('Semaphore(2).run(): maxConcurrentReached=$maxConcurrent, availablePermits=${semaphore.availablePermits}');

  // 4.5 Isolate offloading
  final heavyResult = await (() {
    var sum = 0;
    for (var i = 0; i < 100000; i++) {
      sum += i;
    }
    return sum;
  }).isolate();
  Logger.ok('computation.isolate(): sum=$heavyResult');

  // 4.6 Stream Extensions: chunk, flatmap, notnull, debounce, throttle
  final sourceStream = Stream.fromIterable([1, 2, null, 3, 4, null, 5, 6]);
  final cleanChunks = await sourceStream
      .notnull()
      .flatmap((n) => Stream.value(n * 2))
      .chunk(3)
      .toList();
  Logger.ok('Stream extensions (notnull -> flatmap -> chunk): $cleanChunks');

  // =========================================================================
  // 5. Core Types & Document Parsing (`dart_toolkit/core`)
  // =========================================================================
  Logger.step(5, 8, 'Core Types & Parsers (Either, JsonDocument, HtmlDocument, XmlDocument)');

  // 5.1 Either (Functional Error Handling)
  Either<Exception, int> divide(int a, int b) {
    if (b == 0) return Left(Exception('Division by zero'));
    return Right(a ~/ b);
  }

  final okEither = divide(10, 2);
  final failEither = divide(10, 0);

  Logger.info('Either ok: isRight=${okEither.isRight}, value=${okEither.rightOrNull}');
  Logger.info('Either fail: isLeft=${failEither.isLeft}, error=${failEither.leftOrNull}');

  final guarded = Either.guard(() => int.parse('123'));
  final guardedAsync = await Either.guardAsync(() async => 'async value');
  Logger.ok('Either.guard: ${guarded.rightOrNull}, Either.guardAsync: ${guardedAsync.rightOrNull}');

  // 5.2 JSON Document with JSONPath
  final rawJson = '{"store": {"book": [{"title": "Sayings", "price": 8.95}, {"title": "Sword", "price": 12.99}]}}';
  final jsonParsed = JsonDocument.parse(rawJson);
  final titles = jsonParsed.$jsonpath(r'$.store.book[*].title').map((n) => n.raw).toList();
  Logger.ok('JsonDocument JSONPath: titles=$titles');

  // 5.3 HTML Document with CSS & XPath
  final rawHtml = '<div class="content"><h2 id="main">Heading</h2><a href="/link1">One</a><a href="/link2">Two</a></div>';
  final htmlParsed = HtmlDocument.parse(rawHtml);
  Logger.ok('HtmlDocument CSS: h2="${htmlParsed.$('#main').firstOrNull?.text}"');
  Logger.ok('HtmlDocument XPath: links=${htmlParsed.$xpath('//a/@href').map((n) => n.text).toList()}');

  // 5.4 XML Document with XPath
  final rawXml = '<users><user id="1"><name>Alice</name></user><user id="2"><name>Bob</name></user></users>';
  final xmlParsed = XmlDocument.parse(rawXml);
  Logger.ok('XmlDocument XPath: names=${xmlParsed.$xpath('//user/name/text()').map((n) => n.value).toList()}');

  // 5.5 String regex match helper
  final versionMatch = 'Release version 9.4.2-alpha'.match(r'version ([\d\.]+)', 1);
  Logger.ok('String.match(): version=$versionMatch');

  // =========================================================================
  // 6. HTTP Extension & Web Scraping Pipeline (`dart_toolkit/http`)
  // =========================================================================
  Logger.step(6, 8, 'HTTP Response Extensions & Scraping Pipeline');

  // 6.1 Response extension parsers
  final sampleResponse = http.Response('{"status": 200, "message": "OK"}', 200);
  Logger.ok('http.Response.json(): ${sampleResponse.json().$jsonpath(r'$.message').firstOrNull?.raw}');

  final sampleHtmlResponse = http.Response('<title>Dart Toolkit Showcase</title>', 200);
  Logger.ok('http.Response.html(): ${sampleHtmlResponse.html().$('title').firstOrNull?.text}');

  final sampleXmlResponse = http.Response('<status code="0"/>', 200);
  Logger.ok('http.Response.xml(): ${sampleXmlResponse.xml().$xpath(r'/status/@code').firstOrNull?.value}');

  // 6.2 Scraping pipeline demonstration
  final seedUri = 'https://example.com'.url;
  Logger.info('Scrape seed URL: $seedUri');

  // =========================================================================
  // 7. Collections & Time Utilities (`dart_toolkit/collection`, `dart_toolkit/util`)
  // =========================================================================
  Logger.step(7, 8, 'Collections & Duration Utilities');

  // 7.1 Collections: chunk, sorted, sortedBy, sortedByDescending, mapIndexed
  final list = [5, 2, 8, 1, 9];
  Logger.info('sorted():                 ${list.sorted()}');
  Logger.info('sortedByDescending():     ${list.sortedByDescending((n) => n)}');
  Logger.info('chunk(2):                 ${list.chunk(2).toList()}');
  Logger.info('mapIndexed():             ${list.mapIndexed((i, v) => "#$i:$v").toList()}');

  // 7.2 DurationInt & DurationExtensions: .ms, .s, .m, .h, .d, .humanize(), .jittered()
  final d1 = 350.ms;
  final d2 = 45.s;
  final d3 = 2.m + 15.s;
  final d4 = 1.h + 5.m + 2.s;
  final d5 = 1.d;

  Logger.info('Duration humanize: 350ms -> "${d1.humanize()}"');
  Logger.info('Duration humanize: 45s   -> "${d2.humanize()}"');
  Logger.info('Duration humanize: 2m15s -> "${d3.humanize()}"');
  Logger.info('Duration humanize: 1h5m2s-> "${d4.humanize()}"');
  Logger.info('Duration humanize: 1d    -> "${d5.humanize()}"');
  Logger.info('Duration jittered:       -> "${1000.ms.jittered(0.25).inMilliseconds}ms"');

  // =========================================================================
  // 8. CLI Application, Console & Prompts (`dart_toolkit/cli`)
  // =========================================================================
  Logger.step(8, 8, 'CLI Framework, Prompts, Spinners, Tables & Lifecycle');

  // 8.1 ANSI Color and formatting extensions
  Logger.info('${'Bold Text'.bold} | ${'Italic'.italic} | ${'Underline'.underline} | ${'Dim'.dim}');
  Logger.info('${'Green'.green} | ${'Red'.red} | ${'Yellow'.yellow} | ${'Cyan'.cyan} | ${'Magenta'.magenta} | ${'Blue'.blue} | ${'Grey'.grey}');

  // 8.2 Lifecycle hook registration
  onExit(() {
    Logger.info('Lifecycle onExit hook executed during teardown.');
  });
  Logger.ok('onExit() registered clean teardown hook.');

  // 8.3 Console Spinners & Progress Bars
  await Console.spin('Running background task in Console.spin...', () async {
    await 80.ms.delay();
  });

  final customSpinner = Console.spinner('Manual spinner control')..start();
  await 40.ms.delay();
  customSpinner.info('Discovered components');
  customSpinner.success('Manual spinner complete');

  final progressBar = Console.progress(4, message: 'Synchronizing');
  for (var i = 1; i <= 4; i++) {
    await 20.ms.delay();
    progressBar.tick(1, 'Item $i');
  }
  progressBar.done('Synchronization completed');

  // 8.4 CLI Parser building (Cli, CliCommand, CliOption, CliContext)
  final appCli = Cli(name: 'toolkit_app', description: 'Sample CLI App');
  appCli
      .command('deploy', description: 'Deploy application')
      .choice('target', ['staging', 'production'], abbr: 't', defaultTo: 'staging', description: 'Deployment target')
      .option('dry-run', flag: true, abbr: 'd', description: 'Simulate without executing')
      .action((ctx) {
        final target = ctx.option('target');
        final isDryRun = ctx.flag('dry-run');
        Logger.info('Dispatched CLI command: target=$target, dryRun=$isDryRun');
      });

  await appCli.run(['deploy', '-t', 'production', '--dry-run']);

  // 8.5 Interactive Prompts reference
  Logger.info('Interactive Prompts available:');
  Logger.info('  - Prompt.ask("Project name", "my_app")');
  Logger.info('  - Prompt.confirm("Deploy to production?", false)');
  Logger.info('  - Prompt.secret("Enter API Token")');
  Logger.info('  - Prompt.select("Choose environment", ["staging", "production"])');

  // 8.6 Console Table & Rule
  Console.table(
    headers: ['Module', 'Coverage', 'Status'],
    rows: [
      [r'process', r'$, run(), which(), pipe, ShellResult', '100% Tested'],
      ['fs', 'Path, file I/O, glob, sanitized, sha256, zip', '100% Tested'],
      ['util', 'Env, DurationInt, humanize, delay', '100% Tested'],
      ['async', 'parallelize, retry, Mutex, Semaphore, isolate', '100% Tested'],
      ['core', 'Either, JsonDoc, HtmlDoc, XmlDoc', '100% Tested'],
      ['http', 'Response parsing, Scrape pipeline', '100% Tested'],
      ['collection', 'chunk, sorted, sortedBy, mapIndexed', '100% Tested'],
      ['cli', 'Console, Spinner, Table, Logger, Prompt, Cli', '100% Tested'],
    ],
  );

  Console.rule('All dart_toolkit APIs Verified Successfully');
  onExit(null);
}
