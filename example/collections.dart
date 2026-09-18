import 'package:dart_toolkit/cli.dart';
import 'package:dart_toolkit/collection.dart';

/// The same six tasks twice: with the SDK's `Iterable` and `Map`, then with `Sequence` and
/// `Table`. Both halves print the same thing; the point is what each one takes to say.
typedef Track = ({int disc, int number, String title, String format, int seconds});

const tracks = <Track>[
  (disc: 1, number: 2, title: 'Summer Lights', format: 'flac', seconds: 301),
  (disc: 1, number: 1, title: 'Bird Song', format: 'mp3', seconds: 244),
  (disc: 2, number: 1, title: 'Farewell', format: 'flac', seconds: 412),
  (disc: 1, number: 3, title: 'Reunion', format: 'flac', seconds: 198),
  (disc: 2, number: 2, title: 'Bird Song', format: 'flac', seconds: 244),
];

const pages = [(title: 'Summer Lights', url: '/1'), (title: 'Farewell', url: '/3'), (title: 'Bird Song', url: '/2')];

void main() {
  Console.rule('1. Sort by disc, then by number descending');
  // Iterable: a compound comparator, written by hand, and a copy so the list is not mutated.
  final sortedA = [...tracks]
    ..sort((a, b) => a.disc != b.disc ? a.disc.compareTo(b.disc) : b.number.compareTo(a.number));
  // Sequence: one key per call.
  final sortedB = tracks.sequence.sortedBy((t) => t.disc).thenBy((t) => t.number, descending: true);
  show(sortedA.map((t) => '${t.disc}-${t.number}'), sortedB.map((t) => '${t.disc}-${t.number}'));

  Console.rule('2. Seconds per disc, largest first');
  // Iterable: fold into a map, then sort its entries.
  final perDiscA = <int, int>{};
  for (final t in tracks) {
    perDiscA[t.disc] = (perDiscA[t.disc] ?? 0) + t.seconds;
  }
  final rankedA = perDiscA.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  // Sequence: group, fold each group, sort by value.
  final rankedB = tracks.sequence
      .groupBy((t) => t.disc)
      .mapValues((g) => g.sequence.sum((t) => t.seconds))
      .sortedByValue(descending: true);
  show(rankedA.map((e) => '${e.key}: ${e.value}s'), rankedB.map((r) => '${r.$1}: ${r.$2}s'));

  Console.rule('3. Join tracks to their pages by title');
  // Iterable: index one side by hand, then look up.
  final byTitle = {for (final p in pages) p.title: p};
  final joinedA = [
    for (final t in tracks)
      if (byTitle[t.title] case final p?) '${t.title} -> ${p.url}',
  ];
  // Sequence: a hash join.
  final joinedB = tracks.sequence.innerJoin(
    pages,
    on: (t) => t.title,
    to: (p) => p.title,
    (t, p) => '${t.title} -> ${p.url}',
  );
  show(joinedA, joinedB);

  Console.rule('4. Distinct titles, in first-seen order, and a running total of seconds');
  // Iterable: a Set for the order-preserving dedupe, a loop for the running total.
  final seen = <String>{};
  final distinctA = [
    for (final t in tracks)
      if (seen.add(t.title)) t.title,
  ];
  final runningA = <int>[];
  var acc = 0;
  for (final t in tracks) {
    runningA.add(acc += t.seconds);
  }
  // Sequence: the words for both.
  final distinctB = tracks.sequence.map((t) => t.title).distinct;
  final runningB = tracks.sequence.scan(0, (sum, t) => sum + t.seconds);
  show(distinctA, distinctB);
  show(runningA.map((n) => '$n'), runningB.map((n) => '$n'));

  Console.rule('5. The two longest FLAC tracks per disc');
  // Iterable: group, sort each group, take two, flatten.
  final groupsA = <int, List<Track>>{};
  for (final t in tracks.where((t) => t.format == 'flac')) {
    (groupsA[t.disc] ??= []).add(t);
  }
  final topA = [for (final g in groupsA.values) ...(g..sort((a, b) => b.seconds.compareTo(a.seconds))).take(2)];
  // Sequence: the same sentence, in order.
  final topB = tracks.sequence
      .where((t) => t.format == 'flac')
      .groupBy((t) => t.disc)
      .expand((g) => g.$2.sequence.sortedBy((t) => t.seconds, descending: true).take(2));
  show(topA.map((t) => t.title), topB.map((t) => t.title));

  Console.rule('6. As a table: filter, sort, pick columns, print');
  // Iterable: rows are maps; every step rebuilds them by hand.
  final rowsA = [
    for (final t in tracks)
      if (t.seconds > 200) {'disc': t.disc, 'title': t.title, 'min': (t.seconds / 60).toStringAsFixed(1)},
  ]..sort((a, b) => (a['disc'] as int).compareTo(b['disc'] as int));
  Console.table(
    headers: ['disc', 'title', 'min'],
    rows: [
      for (final r in rowsA) [r['disc'], r['title'], r['min']],
    ],
  );
  // Table: the same, as a query; `show()` prints it, `toCsv()` would write it.
  Table.records(tracks, (t) => {'disc': t.disc, 'title': t.title, 'seconds': t.seconds})
      .where((r) => r.number('seconds')! > 200)
      .orderBy('disc')
      .derive('min', (r) => (r.number('seconds')! / 60).toStringAsFixed(1))
      .select(['disc', 'title', 'min'])
      .show();
  Table.records(
    tracks,
    (t) => {'disc': t.disc, 'format': t.format, 'seconds': t.seconds},
  ).pivot(rows: 'disc', column: 'format', value: 'seconds').show();
}

/// Prints both answers side by side and says whether they agree.
void show(Iterable<String> iterableApi, Iterable<String> sequenceApi) {
  final a = iterableApi.toList(), b = sequenceApi.toList();
  Console.table(
    headers: ['Iterable', 'Sequence'],
    rows: [
      for (var i = 0; i < a.length; i++) [a[i], i < b.length ? b[i] : ''],
    ],
  );
  a.toString() == b.toString() ? Logger.ok('same result') : Logger.error('results differ');
}
