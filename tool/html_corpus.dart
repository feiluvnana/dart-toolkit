// Refetch the real pages behind test/html_corpus_test.dart into
// test/fixtures/html (gzipped UTF-8). Pages that refuse are reported and skipped.
//
//   dart run tool/html_corpus.dart
library;

import 'dart:convert';
import 'dart:io' as io;

import 'package:dart_toolkit/console.dart';
import 'package:dart_toolkit/http.dart';
import 'package:dart_toolkit/pool.dart';

const urls = {
  'wikipedia-en': 'https://en.wikipedia.org/wiki/HTML',
  'wikipedia-ja': 'https://ja.wikipedia.org/wiki/HTML',
  'wikipedia-de': 'https://de.wikipedia.org/wiki/Hypertext_Markup_Language',
  'wikipedia-table': 'https://en.wikipedia.org/wiki/List_of_countries_by_population_(United_Nations)',
  'mdn-table': 'https://developer.mozilla.org/en-US/docs/Web/HTML/Element/table',
  'mdn-selectors': 'https://developer.mozilla.org/en-US/docs/Web/CSS/CSS_selectors',
  'dart-dev': 'https://dart.dev/language',
  'pub-dev': 'https://pub.dev/packages/http',
  'python-docs': 'https://docs.python.org/3/library/html.parser.html',
  'go-dev': 'https://go.dev/doc/effective_go',
  'rust-book': 'https://doc.rust-lang.org/book/ch01-00-getting-started.html',
  'hacker-news': 'https://news.ycombinator.com/',
  'lobsters': 'https://lobste.rs/',
  'github-repo': 'https://github.com/dart-lang/sdk',
  'gnu': 'https://www.gnu.org/philosophy/free-sw.html',
  'kernel': 'https://www.kernel.org/',
  'whatwg-tables': 'https://html.spec.whatwg.org/multipage/tables.html',
  'iana': 'https://www.iana.org/domains/reserved',
  'example': 'https://example.com/',
  'text-npr': 'https://text.npr.org/',
  'lite-cnn': 'https://lite.cnn.com/',
  'bbc': 'https://www.bbc.com/news',
  'guardian': 'https://www.theguardian.com/international',
  'arxiv': 'https://arxiv.org/abs/1706.03762',
  'gutenberg': 'https://www.gutenberg.org/files/1342/1342-h/1342-h.htm',
  'weather-gov': 'https://forecast.weather.gov/MapClick.php?lat=40.7&lon=-74.0',
  'nasa': 'https://www.nasa.gov/',
  'python-org': 'https://www.python.org/',
  'php-manual': 'https://www.php.net/manual/en/function.str-replace.php',
  'sqlite': 'https://www.sqlite.org/lang_select.html',
  'postgres': 'https://www.postgresql.org/docs/current/sql-select.html',
  'nginx': 'https://nginx.org/en/docs/http/ngx_http_core_module.html',
  'apache': 'https://httpd.apache.org/docs/2.4/mod/core.html',
  'debian': 'https://www.debian.org/',
  'mozilla': 'https://www.mozilla.org/en-US/',
  'wordpress': 'https://wordpress.org/',
  'w3schools': 'https://www.w3schools.com/html/html_tables.asp',
  'craigslist': 'https://sfbay.craigslist.org/',
  'puremedia': 'https://puremedia.kr/mall/m_mall_list.php?ps_page=1',
  'yahoo-jp': 'https://www.yahoo.co.jp/',
  'naver': 'https://www.naver.com/',
  'sourcehut': 'https://sr.ht/',
  'archlinux-wiki': 'https://wiki.archlinux.org/title/Installation_guide',
  'rfc': 'https://www.rfc-editor.org/rfc/rfc9110.html',
  'caniuse': 'https://caniuse.com/css-has',
  'hn-item': 'https://news.ycombinator.com/item?id=1',
  'tldp': 'https://tldp.org/LDP/abs/html/index.html',
  'docs-github': 'https://docs.github.com/en/get-started',
  'whatwg-parsing': 'https://html.spec.whatwg.org/multipage/parsing.html',
  'wikipedia-zh': 'https://zh.wikipedia.org/wiki/HTML',
  'openbsd-faq': 'https://www.openbsd.org/faq/faq4.html',
  'freebsd-handbook': 'https://docs.freebsd.org/en/books/handbook/basics/',
};

Future<void> main() async {
  final http = Http.client(
    headers: {
      'user-agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36',
      'accept': 'text/html,application/xhtml+xml',
      'accept-language': 'en-US,en;q=0.9',
    },
    check: true,
    timeout: 30.seconds,
  );
  final out = await Pool.settle(urls.entries, (e) async {
    final text = await http.get(e.value).text();
    await io.File('test/fixtures/html/${e.key}.html.gz').writeAsBytes(io.gzip.encode(utf8.encode(text)));
    return text.length;
  }, limit: 8);
  for (final o in out) {
    switch (o) {
      case Done(:final item, :final value):
        Console.log('✓ ${item.key} $value');
      case Failed(:final item, :final error):
        Console.log('✗ ${item.key}: $error');
    }
  }
  await http.close();
}
