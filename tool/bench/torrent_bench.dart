import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dart_toolkit/torrent.dart';
import 'framework.dart';

const _size = 256 << 20;

/// 4 files of 64 MiB of `Random(1)` bytes in a fresh temp folder, `set/` under it.
Directory _folder(String prefix) {
  final tmp = Directory.systemTemp.createTempSync(prefix);
  final set = Directory('${tmp.path}/set')..createSync();
  final rnd = Random(1);
  for (var i = 0; i < 4; i++) {
    final data = Uint8List(64 << 20);
    for (var j = 0; j < data.length; j++) {
      data[j] = rnd.nextInt(256);
    }
    File('${set.path}/part$i.bin').writeAsBytesSync(data);
  }
  return tmp;
}

/// An HTTP tracker that answers every announce with one peer, 127.0.0.1:[port()].
Future<HttpServer> _tracker(int Function() port) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) {
    final p = port();
    req.response
      ..add([...'d8:intervali60e5:peers6:'.codeUnits, 127, 0, 0, 1, p >> 8, p & 0xFF, ...'e'.codeUnits])
      ..close();
  });
  return server;
}

class TorrentCreateBenchmark extends BenchmarkCase {
  TorrentCreateBenchmark() : super('torrent_create_256mb', module: 'torrent', throughputUnit: 'MB/s');

  late Directory dir;

  @override
  Future<void> setup() async => dir = _folder('bench_torrent_create_');

  @override
  Future<void> teardown() async => dir.deleteSync(recursive: true);

  @override
  int get iterations => 10;

  @override
  Future<int> run(int count) async {
    for (var i = 0; i < count; i++) {
      await Torrent.create('${dir.path}/set');
    }
    return _size * count;
  }
}

/// A seeder and a leecher on loopback (DHT, LSD and UPnP off) moving 256 MiB; the leecher
/// finds the seeder through a local tracker.
class TorrentSwarmBenchmark extends BenchmarkCase {
  TorrentSwarmBenchmark() : super('torrent_swarm_256mb', module: 'torrent', throughputUnit: 'MB/s');

  late Directory dir;
  late HttpServer tracker;
  late Metainfo torrent;
  var _seederPort = 0;

  @override
  Future<void> setup() async {
    dir = _folder('bench_torrent_swarm_');
    tracker = await _tracker(() => _seederPort);
    torrent = await Torrent.create(
      '${dir.path}/set',
      trackers: [Uri.parse('http://127.0.0.1:${tracker.port}/announce')],
    );
  }

  @override
  Future<void> teardown() async {
    await tracker.close(force: true);
    dir.deleteSync(recursive: true);
  }

  @override
  int get iterations => 3;

  @override
  int get warmupIterations => 1;

  @override
  Future<int> run(int count) async {
    for (var i = 0; i < count; i++) {
      final to = Directory('${dir.path}/leech')..createSync();
      final seeder = await TorrentClient.start(into: dir.path, dht: false, lsd: false);
      final leecher = await TorrentClient.start(into: to.path, dht: false, lsd: false);
      try {
        _seederPort = seeder.port;
        seeder.add(torrent); // seeds once its files are checked; the leecher waits for that
        await leecher.add(torrent);
      } finally {
        await seeder.close();
        await leecher.close();
        to.deleteSync(recursive: true); // a fresh folder per run, and 256 MiB less on disk
      }
    }
    return _size * count;
  }
}

List<BenchmarkCase> createTorrentBenchmarks() => [TorrentCreateBenchmark(), TorrentSwarmBenchmark()];
