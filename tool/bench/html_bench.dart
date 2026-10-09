import 'dart:io';
import 'package:dart_toolkit/html.dart';
import 'package:html/parser.dart' as pkg_html;
import 'framework.dart';

class HtmlParseBenchmark extends BenchmarkCase {
  final String htmlContent;
  HtmlParseBenchmark(String name, this.htmlContent)
    : super('html_parse_$name', module: 'formats/html', throughputUnit: 'MB/s');

  @override
  int get iterations => 100;

  @override
  Future<int> run(int count) async {
    for (var i = 0; i < count; i++) {
      final doc = Html.parse(htmlContent);
      if (doc.root.name.isEmpty) throw StateError('fail');
    }
    return htmlContent.length * count;
  }

  @override
  Future<int>? runReference(int count) async {
    for (var i = 0; i < count; i++) {
      final doc = pkg_html.parse(htmlContent);
      if (doc.body == null) throw StateError('fail');
    }
    return htmlContent.length * count;
  }
}

class SelectorBenchmark extends BenchmarkCase {
  final Html doc;
  final String selector;
  SelectorBenchmark(this.doc, this.selector)
    : super(
        'selector_${selector.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_')}',
        module: 'formats/html',
        throughputUnit: 'ops/s',
      );

  @override
  int get iterations => 1000;

  @override
  Future<int> run(int count) async {
    var matches = 0;
    for (var i = 0; i < count; i++) {
      matches += doc.$(selector).length;
    }
    if (matches < 0) throw StateError('fail');
    return count;
  }
}

class XPathBenchmark extends BenchmarkCase {
  final Html doc;
  final String xpath;
  XPathBenchmark(this.doc, this.xpath)
    : super(
        'xpath_${xpath.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_')}',
        module: 'formats/xpath',
        throughputUnit: 'ops/s',
      );

  @override
  int get iterations => 1000;

  @override
  Future<int> run(int count) async {
    var matches = 0;
    for (var i = 0; i < count; i++) {
      matches += doc.$x(xpath).length;
    }
    if (matches < 0) throw StateError('fail');
    return count;
  }
}

List<BenchmarkCase> createHtmlBenchmarks() {
  final sampleHtml = File('test/fixtures/dart_dev.html').existsSync()
      ? File('test/fixtures/dart_dev.html').readAsStringSync()
      : '<html><body>${'<div class="item"><a href="#">Link</a><span>Text</span></div>' * 1000}</body></html>';

  final hnHtml = File('test/fixtures/hn.html').existsSync()
      ? File('test/fixtures/hn.html').readAsStringSync()
      : '<html><body>${'<tr><td class="title"><a href="item">HN Item</a></td></tr>' * 500}</body></html>';

  final doc = Html.parse(sampleHtml);

  return [
    HtmlParseBenchmark('dart_dev', sampleHtml),
    HtmlParseBenchmark('hn', hnHtml),
    SelectorBenchmark(doc, 'a'),
    SelectorBenchmark(doc, '.item'),
    SelectorBenchmark(doc, 'div > a'),
    XPathBenchmark(doc, '//a'),
    XPathBenchmark(doc, '//div[@class="item"]'),
  ];
}
