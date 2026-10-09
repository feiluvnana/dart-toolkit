import 'dart:convert';
import 'package:dart_toolkit/collection.dart';
import 'framework.dart';

class TableCsvParseBenchmark extends BenchmarkCase {
  final String csvContent;
  TableCsvParseBenchmark(this.csvContent) : super('table_csv_parse', module: 'collection', throughputUnit: 'MB/s');

  @override
  int get iterations => 50;

  @override
  Future<int> run(int count) async {
    for (var i = 0; i < count; i++) {
      final t = Table.parse(csvContent, TableFormat.csv);
      if (t.length == 0) throw StateError('fail');
    }
    return csvContent.length * count;
  }
}

class TableNdjsonParseBenchmark extends BenchmarkCase {
  final String ndjsonContent;
  TableNdjsonParseBenchmark(this.ndjsonContent)
    : super('table_ndjson_parse', module: 'collection', throughputUnit: 'MB/s');

  @override
  int get iterations => 50;

  @override
  Future<int> run(int count) async {
    for (var i = 0; i < count; i++) {
      final t = Table.parse(ndjsonContent, TableFormat.ndjson);
      if (t.length == 0) throw StateError('fail');
    }
    return ndjsonContent.length * count;
  }
}

class TableOperationsBenchmark extends BenchmarkCase {
  final Table table;
  TableOperationsBenchmark(this.table) : super('table_query_ops', module: 'collection', throughputUnit: 'ops/s');

  @override
  int get iterations => 100;

  @override
  Future<int> run(int count) async {
    for (var i = 0; i < count; i++) {
      final filtered = table
          .where((r) => (r.get<int>('id') % 2) == 0)
          .orderBy('score', descending: true)
          .groupBy(['category'])
          .agg({'score': Agg.sum('score')});
      if (filtered.length == 0) throw StateError('fail');
    }
    return count;
  }
}

List<BenchmarkCase> createCollectionBenchmarks() {
  final header = 'id,name,category,score,active\n';
  final rows = List.generate(2000, (i) => '$i,User $i,Cat${i % 5},${i * 1.25},${i.isEven}').join('\n');
  final csvContent = header + rows;

  final ndjsonContent = List.generate(
    2000,
    (i) => jsonEncode({'id': i, 'name': 'User $i', 'category': 'Cat${i % 5}', 'score': i * 1.25, 'active': i.isEven}),
  ).join('\n');

  final table = Table.parse(csvContent, TableFormat.csv);

  return [
    TableCsvParseBenchmark(csvContent),
    TableNdjsonParseBenchmark(ndjsonContent),
    TableOperationsBenchmark(table),
  ];
}
