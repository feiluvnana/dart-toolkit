import 'dart:convert';
import 'package:dart_toolkit/json.dart';
import 'package:dart_toolkit/xml.dart';
import 'package:xml/xml.dart' as pkg_xml;
import 'package:yaml/yaml.dart' as pkg_yaml;
import 'framework.dart';

class JsonParseBenchmark extends BenchmarkCase {
  final String jsonStr;
  JsonParseBenchmark(this.jsonStr) : super('json_parse', module: 'formats/json', throughputUnit: 'MB/s');

  @override
  int get iterations => 500;

  @override
  Future<int> run(int count) async {
    for (var i = 0; i < count; i++) {
      final doc = Doc.parse(jsonStr, DocFormat.json);
      if (doc.raw == null) throw StateError('fail');
    }
    return jsonStr.length * count;
  }

  @override
  Future<int>? runReference(int count) async {
    for (var i = 0; i < count; i++) {
      final obj = jsonDecode(jsonStr);
      if (obj == null) throw StateError('fail');
    }
    return jsonStr.length * count;
  }
}

class YamlParseBenchmark extends BenchmarkCase {
  final String yamlStr;
  YamlParseBenchmark(this.yamlStr) : super('yaml_parse', module: 'formats/yaml', throughputUnit: 'MB/s');

  @override
  int get iterations => 300;

  @override
  Future<int> run(int count) async {
    for (var i = 0; i < count; i++) {
      final doc = Doc.parse(yamlStr, DocFormat.yaml);
      if (doc.raw == null) throw StateError('fail');
    }
    return yamlStr.length * count;
  }

  @override
  Future<int>? runReference(int count) async {
    for (var i = 0; i < count; i++) {
      final obj = pkg_yaml.loadYaml(yamlStr);
      if (obj == null) throw StateError('fail');
    }
    return yamlStr.length * count;
  }
}

class XmlParseBenchmark extends BenchmarkCase {
  final String xmlStr;
  XmlParseBenchmark(this.xmlStr) : super('xml_parse', module: 'formats/xml', throughputUnit: 'MB/s');

  @override
  int get iterations => 300;

  @override
  Future<int> run(int count) async {
    for (var i = 0; i < count; i++) {
      final doc = Xml.parse(xmlStr);
      if (doc.root.name.isEmpty) throw StateError('fail');
    }
    return xmlStr.length * count;
  }

  @override
  Future<int>? runReference(int count) async {
    for (var i = 0; i < count; i++) {
      final doc = pkg_xml.XmlDocument.parse(xmlStr);
      if (doc.rootElement.name.local.isEmpty) throw StateError('fail');
    }
    return xmlStr.length * count;
  }
}

class TomlParseBenchmark extends BenchmarkCase {
  final String tomlStr;
  TomlParseBenchmark(this.tomlStr) : super('toml_parse', module: 'formats/toml', throughputUnit: 'MB/s');

  @override
  int get iterations => 500;

  @override
  Future<int> run(int count) async {
    for (var i = 0; i < count; i++) {
      final doc = Doc.parse(tomlStr, DocFormat.toml);
      if (doc.raw == null) throw StateError('fail');
    }
    return tomlStr.length * count;
  }
}

List<BenchmarkCase> createFormatsBenchmarks() {
  final jsonStr = jsonEncode({
    'title': 'Test Document',
    'count': 1000,
    'items': List.generate(
      200,
      (i) => {
        'id': i,
        'name': 'Item $i',
        'price': i * 1.5,
        'active': i.isEven,
        'tags': ['tag1', 'tag2', 'tag$i'],
      },
    ),
  });

  final yamlStr =
      '''
name: dart_toolkit
version: 0.1.0
dependencies:
  path: ^1.9.0
environment:
  sdk: ^3.8.0
items:
${List.generate(50, (i) => '  - id: $i\n    title: Item $i\n    score: ${i * 10}').join('\n')}
''';

  final xmlStr =
      '''
<catalog>
${List.generate(100, (i) => '  <book id="bk$i"><author>Author $i</author><title>Title $i</title><price>${i * 2.5}</price></book>').join('\n')}
</catalog>
''';

  final tomlStr =
      '''
[server]
host = "127.0.0.1"
port = 8080

[database]
enabled = true
connections = 100
timeout = 30.0

${List.generate(20, (i) => '[[items]]\nname = "item_$i"\nvalue = $i').join('\n\n')}
''';

  return [
    JsonParseBenchmark(jsonStr),
    YamlParseBenchmark(yamlStr),
    XmlParseBenchmark(xmlStr),
    TomlParseBenchmark(tomlStr),
  ];
}
