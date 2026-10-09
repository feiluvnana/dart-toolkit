import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_toolkit/hash.dart' show Hash;
import 'package:dart_toolkit/torrent.dart';
import 'package:test/test.dart' hide Retry;

Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  group('Bencode', () {
    test('integers, byte strings, lists and dictionaries, one Dart type each (TOR-17)', () {
      expect(Bencode.decode(_b('i42e')), 42);
      expect(Bencode.decode(_b('i-9223372036854775808e')), -9223372036854775808);
      expect(Bencode.decode(_b('4:spam')), _b('spam'), reason: 'a byte string is always bytes');
      expect(Bencode.decode(Uint8List.fromList([0x32, 0x3A, 0xFF, 0xFE])), [0xFF, 0xFE]);
      expect(Bencode.decode(_b('l4:spami42ee')), [_b('spam'), 42]);
      expect(Bencode.decode(_b('d3:cow3:moo4:spaml1:aee')), {
        'cow': _b('moo'),
        'spam': [_b('a')],
      });
      expect(
        latin1.decode(
          Bencode.encode({
            'z': 1,
            'a': 'é',
            'm': Uint8List.fromList([1]),
          }),
        ),
        'd1:a2:\u00c3\u00a91:m1:\x011:zi1ee',
      );
      expect(ascii.decode(Bencode.encode([1, 2, 3])), 'li1ei2ei3ee', reason: 'a List<int> is a list, not bytes');
    });

    test('a value with no bencode form is an ArgumentError', () {
      expect(() => Bencode.encode({1: 2}), throwsArgumentError, reason: 'keys are never toString()ed');
      expect(() => Bencode.encode(1.5), throwsArgumentError);
      expect(() => Bencode.encode([null]), throwsArgumentError);
    });

    test('malformed input is a FormatException at its offset', () {
      for (final bad in ['i03e', 'i-0e', 'ie', 'i123', '04:spam', '4spam', '10:spam', 'l', 'd1:ae', 'x', 'i1ei2e']) {
        expect(
          () => Bencode.decode(_b(bad)),
          throwsA(isA<FormatException>().having((e) => e.offset, 'offset', isNotNull)),
          reason: bad,
        );
      }
      expect(
        () => Bencode.decode(_b('i99999999999999999999e')),
        throwsA(
          isA<FormatException>().having(
            (e) => '${e.offset} ${e.message}',
            'why',
            contains('0 Invalid bencode at offset 0: integer past 64 bits'),
          ),
        ),
        reason: 'TOR-16: a big integer says where',
      );
    });

    test('nesting is bounded, so an untrusted file never overflows the stack (TOR-16)', () {
      final deep = _b('${'l' * 100000}${'e' * 100000}');
      expect(
        () => Bencode.decode(deep),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('nested'))),
      );
      expect(Bencode.decode(_b('${'l' * 200}${'e' * 200}')), isA<List<Object>>());
    });
  });

  group('Magnet', () {
    test('a hex link with name, trackers and size; toString is the link as given (TOR-18)', () {
      const link =
          'magnet:?xt=urn:btih:DA39A3EE5E6B4B0D3255BFEF95601890AFD80709&dn=Ubuntu%20Linux'
          '&tr=http%3A%2F%2Ftracker.ubuntu.com%2Fannounce&tr=udp%3A%2F%2Ft.example%3A80&xl=2147483648&so=0-2';
      final m = Torrent.parse(link);
      expect(m.infoHash, 'da39a3ee5e6b4b0d3255bfef95601890afd80709');
      expect((m.name, m.size), ('Ubuntu Linux', 2147483648));
      expect(m.trackers, [Uri.parse('http://tracker.ubuntu.com/announce'), Uri.parse('udp://t.example:80')]);
      expect('$m', link, reason: 'every parameter kept');
      expect(link.magnet, m);
    });

    test('a base32 hash reads as hex', () {
      final m = Torrent.parse('magnet:?xt=urn:btih:2N42H3TLNNVQ2MRVX7XZKYAXSCX3QBQI&dn=Sample');
      expect(m.infoHash, 'd379a3ee6b6b6b0d3235bfef95601790afb80608');
    });

    test('a link with no v1 hash is a FormatException saying why (TOR-18)', () {
      Matcher says(String what) => throwsA(isA<FormatException>().having((e) => e.message, 'message', contains(what)));
      expect(() => Torrent.parse('magnet:?dn=Test'), says('no xt=urn:btih:'));
      expect(() => Torrent.parse('magnet:?xt=urn:btmh:1220abcd'), says('v2-only'));
      expect(() => Torrent.parse('magnet:?xt=urn:btih:xyz'), says('40 hex digits'));
      expect(() => Torrent.parse('http://example.com'), says('not a magnet'));
    });
  });

  group('Metainfo', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('tk_torrent_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    Uint8List make(
      String name,
      int piece,
      List<int> payload, {
      List<Map<String, Object>>? files,
      Map<String, Object> extra = const {},
    }) {
      final hashes = <int>[
        for (var i = 0; i < payload.length; i += piece)
          ...Hash.sha1.bytes(payload.sublist(i, i + piece > payload.length ? payload.length : i + piece)).bytes,
      ];
      return Bencode.encode({
        'info': {
          'name': name,
          'piece length': piece,
          'pieces': Uint8List.fromList(hashes),
          if (files != null) 'files': files else 'length': payload.length,
        },
        'created by': 'dart_toolkit',
        'comment': 'test torrent',
        'creation date': 1600000000,
        ...extra,
      });
    }

    test('a single-file torrent', () {
      final payload = utf8.encode('Hello World, this is a test payload for bittorrent verification.');
      final t = Torrent.decode(make('hello.txt', 32, payload, extra: {'announce': 'http://t.example:80/announce'}));
      expect((t.name, t.pieceLength, t.pieceCount, t.size, t.isFolder), ('hello.txt', 32, 2, payload.length, false));
      expect(t.files.single, TorrentFile(path: Path('hello.txt'), size: payload.length, offset: 0));
      expect(t.trackers, [Uri.parse('http://t.example:80/announce')]);
      expect((t.createdBy, t.comment), ('dart_toolkit', 'test torrent'));
      expect(t.creationDate, DateTime.utc(2020, 9, 13, 12, 26, 40));
      expect(t.pieceHashes.first, Hash.sha1.bytes(payload.sublist(0, 32)).hex);
      expect((t.magnet.infoHash, t.magnet.name), (t.infoHash, 'hello.txt'));
    });

    test('a multi-file torrent, BEP 47 padding files left out but counted in offsets (TOR-21)', () {
      final t = Torrent.decode(
        make(
          'set',
          16,
          List.filled(40, 1),
          files: [
            {
              'length': 10,
              'path': [_b('a.txt')],
            },
            {
              'length': 6,
              'path': [_b('.pad'), _b('6')],
              'attr': _b('p'),
            },
            {
              'length': 24,
              'path': [_b('sub'), _b('b.txt')],
            },
          ],
        ),
      );
      expect(t.files.map((f) => ('${f.path}', f.size, f.offset)), [('a.txt', 10, 0), ('sub/b.txt', 24, 16)]);
      expect((t.size, t.isFolder), (34, true));
    });

    test('the info hash is of the info bytes, even when a comment holds "4:infod" (TOR-14)', () {
      final info = {'name': 'x', 'piece length': 16, 'pieces': Uint8List(20), 'length': 1};
      final bytes = Bencode.encode({'comment': 'look: 4:infod1:ai1ee', 'info': info});
      expect(Torrent.decode(bytes).infoHash, Hash.sha1.bytes(Bencode.encode(info)).hex);
    });

    test('encode and save give the bytes back unchanged, so the info hash holds (TOR-13)', () async {
      // Keys out of order and an unknown one: a re-encode would sort them and change the hash.
      final raw = _b('d4:infod6:lengthi1e4:name1:x12:piece lengthi16e6:pieces20:${'\x00' * 20}e1:zi1e1:ai2ee');
      final t = Torrent.decode(raw);
      expect(t.encode(), raw);
      final saved = await t.save('${tmp.path}/a.torrent');
      expect(File(saved).readAsBytesSync(), raw);
      expect((await Torrent.read(saved)).infoHash, t.infoHash);
      t.encode()[0] = 0;
      expect(t.encode(), raw, reason: 'what it hands out is a copy');
    });

    test('names honour utf-8 forms and the encoding key, never "[227, 129, …]" (TOR-15)', () {
      final info = {
        'name': Uint8List.fromList([0x82, 0xA0]),
        'name.utf-8': 'あ',
        'piece length': 16,
        'pieces': Uint8List(20),
        'length': 1,
      };
      expect(Torrent.decode(Bencode.encode({'info': info})).name, 'あ');
      final sjis = {
        'name': Uint8List.fromList([0x82, 0xA0]),
        'piece length': 16,
        'pieces': Uint8List(20),
        'length': 1,
      };
      expect(Torrent.decode(Bencode.encode({'info': sjis, 'encoding': 'Shift_JIS'})).name, 'あ');
      expect(Torrent.decode(Bencode.encode({'info': sjis})).name, '��');
    });

    test('bytes that are no torrent, and a file that is none, are FormatExceptions naming it', () async {
      expect(
        () => Torrent.decode(_b('i42e')),
        throwsA(isA<FormatException>().having((e) => e.message, 'm', contains('Invalid torrent'))),
      );
      final path = '${tmp.path}/bad.torrent';
      File(path).writeAsStringSync('nope');
      await expectLater(
        Torrent.read(path),
        throwsA(isA<FormatException>().having((e) => e.message, 'm', contains(path))),
      );
      await expectLater(Torrent.read('${tmp.path}/none.torrent'), throwsA(isA<PathNotFoundException>()));
    });

    test('verify finds the files where download put them, and reports the bytes checked', () async {
      final a = utf8.encode('AAAA BBBB CCCC DDDD '), b = utf8.encode('EEEE FFFF GGGG HHHH ');
      final t = Torrent.decode(
        make(
          'bundle',
          20,
          [...a, ...b],
          files: [
            {
              'length': a.length,
              'path': [_b('a.txt')],
            },
            {
              'length': b.length,
              'path': [_b('sub'), _b('b.txt')],
            },
          ],
        ),
      );
      File('${tmp.path}/bundle/sub/b.txt')
        ..createSync(recursive: true)
        ..writeAsBytesSync(b);
      File('${tmp.path}/bundle/a.txt').writeAsBytesSync(a);
      final task = t.verify(tmp.path);
      final amounts = task.statuses
          .where((s) => s is Running)
          .cast<Running<Object?, Verification>>()
          .map((r) => r.received)
          .toList();
      final v = await task;
      expect((v.isComplete, v.ratio, v.intact), (true, 1.0, 2));
      expect(v.pieces, [true, true]);
      expect(v.files.map((f) => f.verifiedBytes), [a.length, b.length]);
      expect((await amounts).last, 40);

      File('${tmp.path}/bundle/a.txt').writeAsStringSync('CORRUPTED CONTENTS! ');
      File('${tmp.path}/bundle/sub/b.txt').deleteSync();
      final bad = await t.verify(tmp.path);
      expect((bad.isComplete, bad.intact, bad.files[1].exists), (false, 0, false));
      expect(bad.files[0].corruptedPieces, [0]);
    });

    test('a single-file torrent verifies at dir/<name>', () async {
      final payload = utf8.encode('one file');
      final t = Torrent.decode(make('one.txt', 16, payload));
      File('${tmp.path}/one.txt').writeAsBytesSync(payload);
      expect((await t.verify(tmp.path)).isComplete, isTrue);
    });

    test('a torrent of no pieces is complete, its ratio 1 (TOR-22)', () {
      const v = Verification(pieces: [], files: []);
      expect((v.isComplete, v.ratio), (true, 1.0));
    });

    test('create lists the folder sorted, leaves out OS junk, and reports the bytes hashed (TOR-20, TOR-21)', () async {
      final dir = Directory('${tmp.path}/set')..createSync();
      File('${dir.path}/b.bin').writeAsBytesSync(List.filled(70000, 2));
      File('${dir.path}/a.bin').writeAsBytesSync(List.filled(50000, 1));
      File('${dir.path}/.DS_Store').writeAsBytesSync([0]);
      final trackers = [Uri.parse('udp://a.example:1337/announce'), Uri.parse('http://b.example/announce')];
      final task = Torrent.create(dir.path, trackers: trackers, comment: 'made here');
      final amounts = task.statuses
          .where((s) => s is Running)
          .cast<Running<Object?, Metainfo>>()
          .map((r) => r.received)
          .toList();
      final t = await task;
      expect(t.files.map((f) => '${f.path}'), ['a.bin', 'b.bin']);
      expect((t.name, t.size, t.comment), ('set', 120000, 'made here'));
      expect(t.trackers, trackers);
      expect((await amounts).last, 120000);
      final again = await Torrent.create(dir.path, trackers: t.trackers);
      expect(again.infoHash, t.infoHash, reason: 'the same folder, the same hash');
      expect((await t.verify(tmp.path)).isComplete, isTrue);
    });

    test('create of nothing, a missing path, or a piece length off a power of two', () async {
      Directory('${tmp.path}/empty').createSync();
      await expectLater(Torrent.create('${tmp.path}/empty'), throwsA(isA<MissingException>()));
      await expectLater(Torrent.create('${tmp.path}/none'), throwsA(isA<PathNotFoundException>()));
      expect(() => Torrent.create(tmp.path, pieceLength: 1000), throwsArgumentError);
    });

    test('private changes the info hash and sets the flag', () async {
      final f = File('${tmp.path}/a.bin')..writeAsBytesSync(List.filled(1000, 1));
      final open = await Torrent.create(f.path), private = await Torrent.create(f.path, private: true);
      expect((open.isPrivate, private.isPrivate), (false, true));
      expect(private.infoHash, isNot(open.infoHash));
    });

    test('the fixture reads', () async {
      final t = await Torrent.read('test/fixtures/sample.torrent');
      expect(
        (t.name, t.pieceLength, t.pieceCount, t.comment, t.trackers.length),
        ('sample.txt', 32768, 1, 'Sample fixture torrent', 2),
      );
      expect(t.infoHash, '3c87d05ba50bba5a1dfdca540a79c9112211428a');
    });
  });
}
