import 'dart:typed_data';
import 'package:dart_toolkit/hash.dart';
import 'framework.dart';

class HashBenchmark extends BenchmarkCase {
  final Uint8List data;
  final Hash algorithm;
  HashBenchmark(this.data, this.algorithm)
    : super('hash_${algorithm.name}_1mb', module: 'hash', throughputUnit: 'MB/s');

  @override
  int get iterations => 100;

  @override
  Future<int> run(int count) async {
    for (var i = 0; i < count; i++) {
      final digest = algorithm.bytes(data);
      if (digest.bytes.isEmpty) throw StateError('fail');
    }
    return data.length * count;
  }
}

List<BenchmarkCase> createHashBenchmarks() {
  final data = Uint8List(1024 * 1024); // 1 MB
  for (var i = 0; i < data.length; i++) {
    data[i] = i & 0xff;
  }

  return [
    HashBenchmark(data, Hash.sha256),
    HashBenchmark(data, Hash.sha1),
    HashBenchmark(data, Hash.md5),
    HashBenchmark(data, Hash.blake3),
  ];
}
