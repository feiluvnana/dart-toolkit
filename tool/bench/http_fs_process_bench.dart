import 'dart:io';
import 'package:dart_toolkit/http.dart';
import 'package:dart_toolkit/path.dart';
import 'package:dart_toolkit/process.dart';
import 'framework.dart';

class HttpLocalServerBenchmark extends BenchmarkCase {
  HttpLocalServerBenchmark() : super('http_keep_alive_requests', module: 'http', throughputUnit: 'req/s');

  HttpServer? _server;
  String? _url;
  final client = IoClient();

  @override
  Future<void> setup() async {
    _server = await HttpServer.bind('127.0.0.1', 0);
    _server!.listen((req) {
      req.response
        ..headers.contentType = ContentType.text
        ..write('hello world')
        ..close();
    });
    _url = 'http://127.0.0.1:${_server!.port}';
  }

  @override
  Future<void> teardown() async {
    await client.close();
    await _server?.close(force: true);
  }

  @override
  int get iterations => 100;

  @override
  Future<int> run(int count) async {
    final uri = Uri.parse(_url!);
    await Http.scope(client: client, () async {
      for (var i = 0; i < count; i++) {
        final res = await uri.get();
        if (res.statusCode != 200) throw StateError('fail');
      }
    });
    return count;
  }

  @override
  Future<int>? runReference(int count) async {
    final rawClient = HttpClient();
    final uri = Uri.parse(_url!);
    try {
      for (var i = 0; i < count; i++) {
        final req = await rawClient.getUrl(uri);
        final res = await req.close();
        await res.drain<void>();
        if (res.statusCode != 200) throw StateError('fail');
      }
    } finally {
      rawClient.close(force: true);
    }
    return count;
  }
}

class FsFilesBenchmark extends BenchmarkCase {
  FsFilesBenchmark() : super('fs_files_recursive_1k', module: 'fs', throughputUnit: 'files/s');

  Directory? _tempDir;

  @override
  Future<void> setup() async {
    _tempDir = Directory.systemTemp.createTempSync('bench_fs_');
    for (var i = 0; i < 10; i++) {
      final sub = Directory('${_tempDir!.path}/sub_$i')..createSync();
      for (var j = 0; j < 50; j++) {
        File('${sub.path}/file_$j.txt').writeAsStringSync('content');
      }
    }
  }

  @override
  Future<void> teardown() async {
    _tempDir?.deleteSync(recursive: true);
  }

  @override
  int get iterations => 20;

  @override
  Future<int> run(int count) async {
    var total = 0;
    for (var i = 0; i < count; i++) {
      final files = await Path(_tempDir!.path).files(only: '**').toList();
      total += files.length;
    }
    return total;
  }

  @override
  Future<int>? runReference(int count) async {
    var total = 0;
    for (var i = 0; i < count; i++) {
      final files = await _tempDir!.list(recursive: true).where((e) => e is File).toList();
      total += files.length;
    }
    return total;
  }
}

class ProcessRunBenchmark extends BenchmarkCase {
  ProcessRunBenchmark() : super('process_run_overhead', module: 'process', throughputUnit: 'ops/s');

  @override
  int get iterations => 20;

  @override
  Future<int> run(int count) async {
    for (var i = 0; i < count; i++) {
      final text = await Shell.run('dart --version', quiet: true).text;
      if (text.isEmpty) throw StateError('fail');
    }
    return count;
  }

  @override
  Future<int>? runReference(int count) async {
    for (var i = 0; i < count; i++) {
      final res = await Process.run('dart', ['--version']);
      if (res.exitCode != 0) throw StateError('fail');
    }
    return count;
  }
}

List<BenchmarkCase> createHttpFsProcessBenchmarks() {
  return [HttpLocalServerBenchmark(), FsFilesBenchmark(), ProcessRunBenchmark()];
}
