// The BitTorrent client, on loopback: DHT, LSD and UPnP off; a leecher finds the seeder through a
// tracker served by the test. Only `Torrent.download`'s own client has DHT on (it takes no
// options), so those two tests may send a DHT bootstrap packet; none waits on one.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_toolkit/hash.dart' show Hash;
import 'package:dart_toolkit/torrent.dart';
import 'package:test/test.dart' hide Retry;

/// A client that talks to nothing but the trackers its torrents name.
Future<TorrentClient> _local(String into, {Store? store}) =>
    TorrentClient.start(into: into, store: store, dht: false, lsd: false);

/// A tracker nobody answers at: a torrent that names it never finds a peer.
final _nowhere = Uri.parse('http://127.0.0.1:1/announce');

/// [n] bytes no compressor or deduplication shortcuts.
Uint8List _bytes(int n, int seed) =>
    Uint8List.fromList([for (var i = 0; i < n; i++) (i * 31 + seed + i ~/ 251) & 0xFF]);

/// An HTTP tracker that answers every announce with one peer: 127.0.0.1:[port()].
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

void main() {
  late Directory tmp;
  late String source;
  late HttpServer tracker;
  late TorrentClient seeder;
  late TorrentClient leecher;
  late Metainfo torrent;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('tk_torrent_');
    source = '${tmp.path}/seed/set';
    File('$source/a.bin')
      ..createSync(recursive: true)
      ..writeAsBytesSync(_bytes(3 << 20, 1));
    File('$source/sub/b.bin')
      ..createSync(recursive: true)
      ..writeAsBytesSync(_bytes(1 << 20, 2));
    seeder = await _local('${tmp.path}/seed');
    tracker = await _tracker(() => seeder.port);
    torrent = await Torrent.create(
      source,
      pieceLength: 256 << 10,
      trackers: [Uri.parse('http://127.0.0.1:${tracker.port}/announce')],
    );
    leecher = await _local('${tmp.path}/leech');
    await seeder.add(torrent);
  });

  tearDown(() async {
    await seeder.close();
    await leecher.close();
    await tracker.close(force: true);
    tmp.deleteSync(recursive: true);
  });

  List<int> read(String path) => File(path).readAsBytesSync();

  test('a job is a task of its root: steps, bytes, Done(path), then seeding (TOR-2, TOR-3, TOR-4)', () async {
    final job = leecher.add(torrent);
    final statuses = job.statuses.toList();
    final path = await job;
    expect(path, '${tmp.path}/leech/set');
    final all = await statuses;
    expect(all.last, isA<Done<Torrent, Path>>().having((d) => d.value, 'value', path));
    expect(all.every((s) => identical(s.item, torrent) && s.label == 'set'), isTrue);
    final running = all.whereType<Running<Torrent, Path>>();
    expect(running.map((r) => r.step).toSet().difference({'checking', 'downloading'}), isEmpty);
    expect(
      running.where((r) => r.step == 'downloading').every((r) => r.total == 4 << 20 && r.unit == Unit.bytes),
      isTrue,
    );
    expect(read('$path/a.bin'), read('$source/a.bin'));
    expect(read('$path/sub/b.bin'), read('$source/sub/b.bin'));
    expect(leecher.seeding, [job]);
    expect(leecher.add(torrent), same(job), reason: 'a torrent already here is its job');
    expect(await job.settled, isA<Done<Torrent, Path>>());
  });

  test('a single-file torrent ends at into/<name>, the file itself (TOR-2)', () async {
    final one = await Torrent.create('$source/a.bin', trackers: torrent.trackers);
    await seeder.add(one, into: source);
    expect(await leecher.add(one), '${tmp.path}/leech/a.bin');
    expect(read('${tmp.path}/leech/a.bin'), read('$source/a.bin'));
  });

  test('a magnet steps through metadata, then hands over its Metainfo', () async {
    final job = leecher.add(torrent.magnet);
    expect(job.status, isA<Running<Torrent, Path>>().having((r) => r.step, 'step', 'metadata'));
    final meta = await job.metainfo;
    expect(meta.infoHash, torrent.infoHash);
    expect(meta.files.map((f) => f.size), [3 << 20, 1 << 20]);
    await job;
    expect(read('${tmp.path}/leech/set/sub/b.bin'), read('$source/sub/b.bin'));
  });

  test('files: downloads only the files picked; a bad index or maxPeers is an ArgumentError', () async {
    expect(() => leecher.add(torrent, files: [2]), throwsArgumentError);
    expect(() => leecher.add(torrent, maxPeers: 0), throwsArgumentError);
    final job = leecher.add(torrent, files: [1], maxPeers: 5);
    await job;
    expect(read('${tmp.path}/leech/set/sub/b.bin'), read('$source/sub/b.bin'));
    final a = File('${tmp.path}/leech/set/a.bin');
    expect(!a.existsSync() || a.lengthSync() < 3 << 20 || read(a.path).any((b) => b != 0), isTrue);
  });

  test('read waits out the check of what is on disk, never failing "initializing"', () async {
    final copy = '${tmp.path}/copy';
    File('$copy/set/a.bin')
      ..createSync(recursive: true)
      ..writeAsBytesSync(_bytes(3 << 20, 1));
    File('$copy/set/sub/b.bin')
      ..createSync(recursive: true)
      ..writeAsBytesSync(_bytes(1 << 20, 2));
    final other = await _local(copy);
    addTearDown(other.close);
    final job = other.add(torrent);
    final got = BytesBuilder(copy: false);
    await job.read(1).forEach(got.add);
    expect(got.takeBytes(), _bytes(1 << 20, 2));
  });

  test('read streams a file as its pieces arrive, from an offset too', () async {
    final job = leecher.add(torrent);
    final got = BytesBuilder(copy: false);
    await job.read(0).forEach(got.add);
    expect(got.takeBytes(), read('$source/a.bin'));
    final tail = BytesBuilder(copy: false);
    await job.read(1, start: (1 << 20) - 10).forEach(tail.add);
    expect(tail.takeBytes(), read('$source/sub/b.bin').sublist((1 << 20) - 10));
    expect(() => job.read(-1), throwsArgumentError);
  });

  test('pause, resume and remove(deleteFiles: true)', () async {
    final job = leecher.add(torrent)..pause();
    await job.statuses.firstWhere((s) => s is Paused);
    expect(job.status, isA<Paused<Torrent, Path>>());
    job.resume();
    await job;
    expect(leecher.jobs, [job]);
    await job.remove(deleteFiles: true);
    expect(leecher.jobs, isEmpty);
    expect(File('${tmp.path}/leech/set/a.bin').existsSync(), isFalse);
  });

  test('a cancel where it was added stops a magnet that finds no peer, at once', () async {
    final lonely = await Torrent.create('$source/a.bin', name: 'lonely', private: true, trackers: [_nowhere]);
    final started = DateTime.now();
    await expectLater(
      Cancel.scope(timeout: const Duration(milliseconds: 300), () => leecher.add(lonely.magnet)),
      throwsA(isA<CancelledException>()),
    );
    expect(DateTime.now().difference(started), lessThan(const Duration(seconds: 2)));
    expect(leecher.jobs.single.status, isA<Stopped<Torrent, Path>>(), reason: 'stopped, kept until removed');
    await expectLater(leecher.jobs.single.metainfo, throwsA(isA<CancelledException>()));
  });

  test('store: a restarted client resumes its torrents; another version is a FormatException', () async {
    final store = Store('${tmp.path}/state');
    var client = await _local('${tmp.path}/leech', store: store);
    await client.add(torrent);
    await client.close();
    client = await _local('${tmp.path}/leech', store: store);
    addTearDown(client.close);
    final restored = client.jobs.single;
    expect((restored.item.infoHash, restored.item is Metainfo), (torrent.infoHash, true));
    expect(await restored, '${tmp.path}/leech/set');
    File('${tmp.path}/other/torrent.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('{"version": 99}');
    await expectLater(_local(tmp.path, store: Store('${tmp.path}/other')), throwsFormatException);
  });

  test('Torrent.download starts a client and closes it after; nothing seeds, nothing hangs (X-10)', () async {
    final task = torrent.download(into: '${tmp.path}/dl');
    final steps = task.statuses.where((s) => s is Running).cast<Running<Object?, Path>>().map((r) => r.step).toList();
    expect(await task, '${tmp.path}/dl/set');
    expect(read('${tmp.path}/dl/set/a.bin'), read('$source/a.bin'));
    expect(await steps, contains('downloading'), reason: "the job's progress is the task's");
  });

  test('a cancelled download runs its cleanup and ends Stopped (X-10)', () async {
    final lonely = await Torrent.create('$source/a.bin', name: 'lonely', private: true, trackers: [_nowhere]);
    final task = lonely.magnet.download(into: '${tmp.path}/dl');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final started = DateTime.now();
    task.cancel('enough');
    expect(await task.settled, isA<Stopped<Object?, Path>>().having((s) => s.reason, 'reason', 'enough'));
    expect(DateTime.now().difference(started), lessThan(const Duration(seconds: 2)));
  });

  group('file indices', () {
    test('count no BEP 47 padding file, as Metainfo.files does: read(1) is the second real file', () async {
      const piece = 16384;
      final a = _bytes(100, 3), b = _bytes(100, 4);
      final first = Uint8List(piece)..setRange(0, a.length, a);
      final padded = Torrent.decode(
        Bencode.encode({
          'info': {
            'name': 'padded',
            'piece length': piece,
            'pieces': Uint8List.fromList([...Hash.sha1.bytes(first).bytes, ...Hash.sha1.bytes(b).bytes]),
            'files': [
              {
                'length': a.length,
                'path': ['a.bin'],
              },
              {
                'length': piece - a.length,
                'path': ['.pad', '${piece - a.length}'],
                'attr': 'p',
              },
              {
                'length': b.length,
                'path': ['b.bin'],
              },
            ],
          },
        }),
      );
      final dir = '${tmp.path}/padded';
      File('$dir/padded/a.bin')
        ..createSync(recursive: true)
        ..writeAsBytesSync(a);
      File('$dir/padded/b.bin').writeAsBytesSync(b);
      final client = await _local(dir);
      addTearDown(client.close);
      final job = client.add(padded);
      await job;
      final got = BytesBuilder(copy: false);
      await job.read(1).forEach(got.add);
      expect(got.takeBytes(), b);
    });
  });

  group('restarting', () {
    test('a job cancelled before the engine had it is added afresh', () async {
      final job = leecher.add(torrent)..cancel('changed my mind');
      expect(await job.settled, isA<Stopped<Torrent, Path>>());
      final again = leecher.add(torrent);
      expect(again, isNot(same(job)));
      expect(await again, '${tmp.path}/leech/set');
    });

    test('a job cancelled while it downloads runs again when added again, a new outcome to await', () async {
      final lonely = await Torrent.create('$source/a.bin', name: 'lonely', private: true, trackers: [_nowhere]);
      final job = leecher.add(lonely);
      await job.statuses.firstWhere((s) => s is Running<Torrent, Path> && s.step == 'downloading');
      job.cancel('later');
      expect(await job.settled, isA<Stopped<Torrent, Path>>());
      final again = leecher.add(lonely);
      expect(again, same(job));
      expect(again.status, isA<Running<Torrent, Path>>());
      final next = again.settled;
      again.cancel('done looking');
      expect(await next, isA<Stopped<Torrent, Path>>().having((s) => s.reason, 'reason', 'done looking'));
    });
  });

  group('read', () {
    test('cancelling the subscription stops a read that waits on pieces no peer sends', () async {
      final lonely = await Torrent.create('$source/a.bin', name: 'lonely', private: true, trackers: [_nowhere]);
      final job = leecher.add(lonely);
      final sub = job.read(0).listen((_) {});
      await job.statuses.firstWhere((s) => s is Running<Torrent, Path> && s.step == 'downloading');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await sub.cancel();
      expect(job.status, isA<Running<Torrent, Path>>(), reason: 'the job runs on; only the read stopped');
    });

    test('a cancel where it was made ends it with a CancelledException', () async {
      final lonely = await Torrent.create('$source/a.bin', name: 'alone', private: true, trackers: [_nowhere]);
      final job = leecher.add(lonely);
      await expectLater(
        Cancel.scope(timeout: const Duration(milliseconds: 500), () => job.read(0).toList()),
        throwsA(isA<CancelledException>()),
      );
    });
  });

  test(
    'limit takes null for none and refuses 0; a bad port is an ArgumentError; a closed client a StateError (TOR-12)',
    () async {
      leecher.limit(download: 5 << 20);
      leecher.limit();
      expect(() => leecher.limit(download: 0), throwsArgumentError);
      expect(() => leecher.limit(upload: -1), throwsArgumentError);
      await expectLater(TorrentClient.start(into: tmp.path, port: 0), throwsArgumentError);
      await leecher.close();
      expect(() => leecher.add(torrent), throwsStateError);
      expect(() => leecher.port, throwsStateError);
    },
  );
}
