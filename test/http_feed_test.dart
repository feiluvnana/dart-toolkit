// Feed: a newest-first listing walked page by page, with a cursor that
// survives an interrupted run.
import 'dart:async';
import 'dart:io';

import 'package:dart_toolkit/http.dart';
import 'package:test/test.dart';

import 'support/poll.dart';

/// Pages of three numbers, newest first: cursor `p<n>` is page n.
({List<int> items, String? next}) _page(String? cursor, int last) {
  final n = cursor == null ? 0 : int.parse(cursor.substring(1));
  return (items: [for (var i = 0; i < 3; i++) n * 3 + i], next: n < last ? 'p${n + 1}' : null);
}

void main() {
  late Directory tmp;
  late String cursor;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('feed');
    cursor = '${tmp.path}/sub/.cursor';
  });
  tearDown(() => tmp.delete(recursive: true));

  void saveCursor(String text) => (File(cursor)..createSync(recursive: true)).writeAsStringSync(text);

  test('walks every page to the end, in order; the cursor goes once all is done', () async {
    final seen = <int>[];
    final complete = await Feed((c) async => _page(c, 2), cursor: cursor).run((page) => seen.addAll(page.items()));
    expect(complete, isTrue);
    expect(seen, [0, 1, 2, 3, 4, 5, 6, 7, 8]);
    expect(File(cursor).existsSync(), isFalse);
  });

  test('stop() ends the walk at that page (the rest is known); the callback may be async', () async {
    var pages = 0;
    final complete = await Feed((c) async => _page(c, 9)).run((page) async {
      await Future<void>.delayed(Duration.zero); // a file check, say
      if (++pages == 2) page.stop();
    });
    expect((complete, pages), (false, 2));
  });

  test('the cursor moves past a page only once its work succeeded, and never past a failure', () async {
    final work = [for (var i = 0; i < 4; i++) Completer<bool>()];
    var n = 0;
    final run = Feed((c) async => _page(c, 9), cursor: cursor).run(
      (page) => n < 4 ? page.add(work[n++].future) : page.stop(),
    );
    await pumpEventQueue();
    expect(n, 4, reason: 'pages are listed while earlier work still runs');
    work[0].complete(true);
    expect(await eventually(() => File(cursor).existsSync() && File(cursor).readAsStringSync() == 'p1'), isTrue);
    work[1].complete(false); // a failed download: a rerun starts from here
    work[2].completeError(StateError('boom')); // a throwing one is a failure, never an unhandled error
    work[3].complete(true);
    expect(await run, isFalse);
    expect(File(cursor).readAsStringSync(), 'p1');
  });

  test('an interrupted run continues: the top first, up to what is known, then the saved cursor', () async {
    saveCursor('p5\n');
    final firsts = <int>[];
    final complete = await Feed((c) async => _page(c, 6), cursor: cursor).run((page) {
      if (page.items().first == 3) return page.stop(); // page 1 is already down
      firsts.add(page.items().first);
    });
    expect(firsts, [0, 15, 18]);
    expect(complete, isTrue);
    expect(File(cursor).existsSync(), isFalse);
  });

  test('all: a full re-list from the top, whatever cursor is saved', () async {
    saveCursor('p5');
    final firsts = <int>[];
    final complete = await Feed((c) async => _page(c, 3), cursor: cursor).run(
      (page) => firsts.add(page.items().first),
      all: true,
    );
    expect(complete, isTrue);
    expect(firsts, [0, 3, 6, 9]);
    expect(File(cursor).existsSync(), isFalse);
  });

  test('a page error fails the run and keeps the last good cursor', () async {
    final feed = Feed<int>((c) async => c == 'p2' ? throw const SocketException('down') : _page(c, 5), cursor: cursor);
    await expectLater(feed.run((page) => page.add(Future.value(true))), throwsA(isA<SocketException>()));
    expect(File(cursor).readAsStringSync(), 'p2');
  });
}
