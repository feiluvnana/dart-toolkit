import 'dart:async';

import 'package:dart_toolkit/scrape.dart';
import 'package:test/test.dart';

import 'support/child.dart';

sealed class Job {}

final class Listing extends Job {
  Listing(this.page);
  final int page;
  @override
  bool operator ==(Object other) => other is Listing && other.page == page;
  @override
  int get hashCode => page;
}

final class Detail extends Job {
  Detail(this.url);
  final String url;
}

void main() {
  test('pagination and fan-out: queue the next page and every link, emit results', () async {
    final site = {
      1: ['a', 'b'],
      2: ['b', 'c'],
      3: <String>[],
    };
    final fetched = <Object>[];
    final out = await Scrape<Job, String>(key: (j) => j is Detail ? j.url : j)
        .run(
          [Listing(1)],
          onItem: (v) async {
            switch (v.item) {
              case Listing(:final page):
                fetched.add(page);
                final links = site[page]!;
                for (final l in links) {
                  v.add(Detail(l));
                }
                if (links.isNotEmpty) v.add(Listing(page + 1));
              case Detail(:final url):
                fetched.add(url);
                v.emit(url.toUpperCase());
            }
          },
        )
        .toList();
    expect(out.toSet(), {'A', 'B', 'C'});
    expect(fetched.where((f) => f == 'b'), hasLength(1), reason: 'key: dedupes across pages');
    expect(fetched.whereType<int>(), [1, 2, 3]);
  });

  test('items dedupe by == without key; a cursor loop ends by itself', () async {
    final out = await Scrape<String?, int>(limit: 1)
        .run(
          [null],
          onItem: (v) {
            final n = v.item == null ? 0 : int.parse(v.item!);
            v.emit(n);
            final queued = v.add(n < 3 ? '${n + 1}' : null); // null was the seed: dropped, so the run ends
            expect(queued, n < 3);
          },
        )
        .toList();
    expect(out, [0, 1, 2, 3]);
  });

  test('onError gets the visit and may queue a replacement; retries come first', () async {
    var tries = 0;
    final seen = <String>[];
    final out = await Scrape<String, String>(retries: 1)
        .run(
          ['flaky', 'dead'],
          onItem: (v) async {
            seen.add(v.item);
            if (v.item == 'flaky' && tries++ == 0) throw StateError('once');
            if (v.item == 'dead') throw StateError('gone');
            v.emit(v.item);
          },
          onError: (v, e) => v.add('mirror-of-${v.item}'),
        )
        .toList();
    expect(out.toSet(), {'flaky', 'mirror-of-dead'});
    expect(seen.where((s) => s == 'dead'), hasLength(2), reason: 'retried once before onError');
  });

  test('without onError the first failure stops new items and is rethrown', () async {
    final started = <int>[];
    final run = Scrape<int, int>(limit: 1).run(
      [1, 2, 3],
      onItem: (v) {
        started.add(v.item);
        if (v.item == 1) throw StateError('bad');
        v.emit(v.item);
      },
    );
    await expectLater(run.toList(), throwsStateError);
    expect(started, [1]);
  });

  test('limit caps handlers in flight; rate paces starts; onProgress hears a growing total', () async {
    var running = 0, peak = 0;
    final progress = <(int, int)>[];
    await Scrape<int, void>(limit: 2, onProgress: (d, t) => progress.add((d, t)))
        .run(
          [1],
          onItem: (v) async {
            running++;
            peak = peak < running ? running : peak;
            if (v.item == 1) {
              for (var i = 2; i <= 5; i++) {
                v.add(i);
              }
            }
            await Future<void>.delayed(const Duration(milliseconds: 20));
            running--;
          },
        )
        .drain<void>();
    expect(peak, 2);
    expect(progress.last, (5, 5));
    final starts = <DateTime>[];
    await Scrape<int, void>(rate: Rate(1, 100.milliseconds))
        .run([1, 2, 3], onItem: (_) => starts.add(DateTime.now()))
        .drain<void>();
    expect(starts.last.difference(starts.first), greaterThanOrEqualTo(const Duration(milliseconds: 190)));
  });

  test('cancelling the stream stops new items', () async {
    var handled = 0;
    final run = Scrape<int, int>(limit: 1).run(
      [0],
      onItem: (v) async {
        handled++;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        v.emit(v.item);
        v.add(v.item + 1);
      },
    );
    expect(await run.take(3).toList(), [0, 1, 2]);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(handled, lessThanOrEqualTo(4));
  });

  test('a cancelled run ends its rate waits and backoffs, so the script exits at once', () async {
    final sw = Stopwatch()..start();
    final r = await runDart('''
import 'package:dart_toolkit/core.dart';
import 'package:dart_toolkit/scrape.dart';
Future<void> main() async {
  final paced = Scrape<int, int>(rate: Rate(1, const Duration(seconds: 20)));
  print(await paced.run([1, 2, 3], onItem: (v) => v.emit(v.item)).first);
  final failing = Scrape<int, int>(retries: 8);
  final sub = failing.run([1], onItem: (v) => throw Exception('down')).listen((_) {}, onError: (_) {});
  await Future<void>.delayed(const Duration(milliseconds: 200));
  await sub.cancel();
}
''', timeout: const Duration(seconds: 15));
    expect((r.exitCode, '${r.stdout}'.trim()), (0, '1'), reason: '${r.stderr}');
    expect(sw.elapsed, lessThan(const Duration(seconds: 8)));
  });
}
